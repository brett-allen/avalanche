package peer

import "core:net"
import "core:sys/posix"
import "core:time"

HANDSHAKE_TIMEOUT :: 5 * time.Second

Exchange :: struct {
	remote:        Handshake,
	extended:      Extended_Handshake,
	got_extended:  bool,
	metadata:      []byte,
	got_metadata:  bool,
	metadata_err:  Error,
}

exchange_destroy :: proc(ex: ^Exchange, allocator := context.allocator) {
	if ex == nil {
		return
	}
	extended_destroy(&ex.extended, allocator)
	delete(ex.metadata, allocator)
	if ex.metadata_err.message != "" {
		delete(ex.metadata_err.message, allocator)
	}
	ex^ = {}
}

exchange_handshake :: proc(
	endpoint: net.Endpoint,
	local: Handshake,
	timeout: time.Duration = HANDSHAKE_TIMEOUT,
	allocator := context.allocator,
) -> (
	remote: Handshake,
	err: Error,
) {
	ex, xerr := exchange_peer(endpoint, local, 0, timeout, allocator)
	return ex.remote, xerr
}

exchange_peer :: proc(
	endpoint: net.Endpoint,
	local: Handshake,
	listen_port: u16 = 0,
	timeout: time.Duration = HANDSHAKE_TIMEOUT,
	allocator := context.allocator,
) -> (
	ex: Exchange,
	err: Error,
) {
	sock, cerr := dial_tcp_timeout(endpoint, timeout, allocator)
	if cerr.kind != .None {
		return {}, cerr
	}
	defer net.close(sock)

	out, eerr := encode_handshake(local, allocator)
	if eerr.kind != .None {
		return {}, eerr
	}
	defer delete(out, allocator)

	if werr := write_all(sock, out, allocator); werr.kind != .None {
		return {}, werr
	}

	in_buf: [HANDSHAKE_SIZE]byte
	if rerr := read_all(sock, in_buf[:], allocator); rerr.kind != .None {
		return {}, rerr
	}

	ex.remote, err = decode_handshake(in_buf[:], allocator)
	if err.kind != .None {
		return {}, err
	}
	if ex.remote.info_hash != local.info_hash {
		return {}, peer_fail(.Protocol, "peer infohash mismatch", allocator)
	}

	if has_extension(local) && has_extension(ex.remote) {
		ext, got, xerr := exchange_extended(sock, listen_port, allocator)
		if xerr.kind != .None {
			if xerr.message != "" {
				delete(xerr.message, allocator)
			}
			extended_destroy(&ext, allocator)
		} else {
			ex.extended = ext
			ex.got_extended = got
			if got {
				raw, mok, merr := fetch_metadata(sock, ext, local.info_hash, allocator)
				if mok {
					ex.metadata = raw
					ex.got_metadata = true
				} else {
					ex.metadata_err = merr
				}
			}
		}
	}
	return ex, {}
}

@(private)
exchange_extended :: proc(
	sock: net.TCP_Socket,
	listen_port: u16,
	allocator := context.allocator,
) -> (
	ext: Extended_Handshake,
	ok: bool,
	err: Error,
) {
	payload, perr := encode_extended_handshake(listen_port, allocator)
	if perr.kind != .None {
		return {}, false, perr
	}
	defer delete(payload, allocator)

	if werr := write_message(sock, Message{id = .Extended, payload = payload}, allocator); werr.kind != .None {
		return {}, false, werr
	}

	for _ in 0 ..< MAX_SKIP_MESSAGES {
		msg, merr := read_message(sock, allocator)
		if merr.kind != .None {
			return {}, false, merr
		}
		if msg.keep_alive {
			continue
		}
		if msg.id == .Extended && len(msg.payload) > 0 && msg.payload[0] == EXT_HANDSHAKE_ID {
			ext, err = decode_extended_handshake(msg.payload, allocator)
			message_destroy(&msg, allocator)
			if err.kind != .None {
				return {}, false, err
			}
			return ext, true, {}
		}
		message_destroy(&msg, allocator)
	}
	return {}, false, {}
}

@(private)
dial_tcp_timeout :: proc(endpoint: net.Endpoint, timeout: time.Duration, allocator := context.allocator) -> (sock: net.TCP_Socket, err: Error) {
	if endpoint.port == 0 || endpoint.address == nil {
		return 0, peer_fail(.Invalid, "invalid peer endpoint", allocator)
	}
	created, cerr := net.create_socket(net.family_from_endpoint(endpoint), .TCP)
	if cerr != nil {
		return 0, peer_fail(.Connect, "could not create TCP socket", allocator)
	}
	sock = created.(net.TCP_Socket)
	if net.set_blocking(sock, false) != nil {
		net.close(sock)
		return 0, peer_fail(.Connect, "could not set non-blocking socket", allocator)
	}

	sockaddr := endpoint_to_sockaddr(endpoint)
	if posix.connect(posix.FD(sock), (^posix.sockaddr)(&sockaddr), posix.socklen_t(sockaddr.ss_len)) != .OK {
		if posix.get_errno() != .EINPROGRESS {
			net.close(sock)
			return 0, peer_fail(.Connect, "could not connect to peer", allocator)
		}
		pfd := posix.pollfd {
			fd     = posix.FD(sock),
			events = {.OUT},
		}
		n := posix.poll(&pfd, 1, i32(time.duration_milliseconds(timeout)))
		if n == 0 {
			net.close(sock)
			return 0, peer_fail(.Timeout, "connect timed out", allocator)
		}
		if n < 0 || .ERR in pfd.revents || .NVAL in pfd.revents {
			net.close(sock)
			return 0, peer_fail(.Connect, "could not connect to peer", allocator)
		}
		so_err: i32
		so_len := posix.socklen_t(size_of(so_err))
		if posix.getsockopt(posix.FD(sock), posix.SOL_SOCKET, .ERROR, &so_err, &so_len) != .OK || so_err != 0 {
			net.close(sock)
			return 0, peer_fail(.Connect, "could not connect to peer", allocator)
		}
	}

	if net.set_blocking(sock, true) != nil {
		net.close(sock)
		return 0, peer_fail(.Connect, "could not set blocking socket", allocator)
	}
	_ = net.set_option(sock, .Send_Timeout, timeout)
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	return sock, {}
}

@(private)
write_all :: proc(sock: net.TCP_Socket, data: []byte, allocator := context.allocator) -> Error {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil {
			return peer_fail(.IO, "handshake send failed", allocator)
		}
		if n == 0 {
			return peer_fail(.IO, "handshake send closed", allocator)
		}
		sent += n
	}
	return {}
}

@(private)
read_all :: proc(sock: net.TCP_Socket, data: []byte, allocator := context.allocator) -> Error {
	got := 0
	for got < len(data) {
		n, err := net.recv_tcp(sock, data[got:])
		if err == .Timeout {
			return peer_fail(.Timeout, "handshake timed out", allocator)
		}
		if err != nil {
			return peer_fail(.IO, "handshake receive failed", allocator)
		}
		if n == 0 {
			return peer_fail(.Protocol, "peer closed during handshake", allocator)
		}
		got += n
	}
	return {}
}

@(private)
endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: posix.sockaddr_storage) {
	switch a in ep.address {
	case net.IP4_Address:
		(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in {
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(posix.in_addr)a,
			sin_family = .INET,
			sin_len    = size_of(posix.sockaddr_in),
		}
	case net.IP6_Address:
		(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6 {
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(posix.in6_addr)a,
			sin6_family = .INET6,
			sin6_len    = size_of(posix.sockaddr_in6),
		}
	}
	return
}
