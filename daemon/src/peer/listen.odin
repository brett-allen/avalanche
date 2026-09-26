package peer

import "core:net"
import "core:sys/posix"
import "core:time"

listen_peers :: proc(port: u16, allocator := context.allocator) -> (sock: net.TCP_Socket, err: Error) {
	ep := net.Endpoint{address = net.IP4_Any, port = int(port if port != 0 else 6881)}
	created, nerr := net.listen_tcp(ep)
	if nerr != nil {
		return 0, peer_fail(.Connect, "could not listen for peers", allocator)
	}
	if net.set_blocking(created, false) != nil {
		net.close(created)
		return 0, peer_fail(.Connect, "could not set non-blocking listen socket", allocator)
	}
	return created, {}
}

@(private)
accept_tcp_timeout :: proc(
	listener: net.TCP_Socket,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	client: net.TCP_Socket,
	err: Error,
) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < timeout {
		remaining := timeout - time.tick_since(deadline)
		ms := i32(time.duration_milliseconds(remaining))
		if ms < 1 {
			ms = 1
		}
		pfd := posix.pollfd {
			fd     = posix.FD(listener),
			events = {.IN},
		}
		n := posix.poll(&pfd, 1, ms)
		if n <= 0 {
			continue
		}
		c, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			continue
		}
		if net.set_blocking(c, true) != nil {
			net.close(c)
			continue
		}
		return c, {}
	}
	return 0, peer_fail(.Timeout, "accept timed out", allocator)
}

// accept_session accepts one inbound peer and optionally fetches ut_metadata.
accept_session :: proc(
	listener: net.TCP_Socket,
	local: Handshake,
	listen_port: u16 = 0,
	want_metadata: bool = false,
	want_hash: [20]u8 = {},
	timeout: time.Duration = HANDSHAKE_TIMEOUT,
	allocator := context.allocator,
) -> (
	ps: Peer_Session,
	metadata: []byte,
	err: Error,
) {
	if listener == 0 {
		return {}, nil, peer_fail(.Invalid, "nil listen socket", allocator)
	}

	client, aerr := accept_tcp_timeout(listener, timeout, allocator)
	if aerr.kind != .None {
		return {}, nil, aerr
	}
	ps.sock = client
	ps.peer_choking = true
	ps.pex.allocator = allocator

	_ = net.set_option(client, .Receive_Timeout, timeout)
	_ = net.set_option(client, .Send_Timeout, timeout)

	// Inbound: read their handshake first, then send ours.
	in_buf: [HANDSHAKE_SIZE]byte
	if rerr := read_all(client, in_buf[:], allocator); rerr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, rerr
	}
	ps.remote, err = decode_handshake(in_buf[:], allocator)
	if err.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, err
	}
	if ps.remote.info_hash != local.info_hash {
		peer_session_destroy(&ps, allocator)
		return {}, nil, peer_fail(.Protocol, "peer infohash mismatch", allocator)
	}

	out, eerr := encode_handshake(local, allocator)
	if eerr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, eerr
	}
	defer delete(out, allocator)
	if werr := write_all(client, out, allocator); werr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, werr
	}

	ps.bitfield = bitfield_make(0, allocator)
	_ = net.set_option(client, .Receive_Timeout, DOWNLOAD_TIMEOUT)
	_ = net.set_option(client, .Send_Timeout, DOWNLOAD_TIMEOUT)

	if has_extension(local) && has_extension(ps.remote) {
		if xerr := send_extended_handshake(client, listen_port, allocator); xerr.kind != .None {
			peer_session_destroy(&ps, allocator)
			return {}, nil, xerr
		}
	}

	for _ in 0 ..< MAX_SKIP_MESSAGES {
		if want_metadata && ps.got_extended {
			break
		}
		if !has_extension(ps.remote) {
			break
		}
		msg, merr := read_message(client, allocator)
		if merr.kind != .None {
			if merr.message != "" {
				delete(merr.message, allocator)
			}
			break
		}
		apply_wire_message(&ps, msg, allocator)
		message_destroy(&msg, allocator)
	}

	if want_metadata && ps.got_extended {
		size := ps.extended.metadata_size
		_, has_ut := extension_id(ps.extended, UT_METADATA)
		if has_ut && size > 0 {
			raw, ok, merr := fetch_metadata(client, ps.extended, want_hash, allocator)
			if ok {
				metadata = raw
			} else if merr.kind != .None {
				if merr.message != "" {
					delete(merr.message, allocator)
				}
			}
		} else if has_ut {
			_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
			harvest_pex_into(client, &ps, allocator)
			_ = net.set_option(client, .Receive_Timeout, DOWNLOAD_TIMEOUT)
		}
	}
	return ps, metadata, {}
}
