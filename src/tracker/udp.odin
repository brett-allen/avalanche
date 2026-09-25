/*
	UDP tracker protocol (BEP 15).
*/
package tracker

import "core:crypto"
import "core:encoding/endian"
import "core:net"
import "core:strings"
import "core:time"

PROTOCOL_ID :: u64(0x41727101980)

UDP_Action :: enum u32 {
	Connect  = 0,
	Announce = 1,
	Scrape   = 2,
	Error    = 3,
}

UDP_CONNECT_SIZE  :: 16
UDP_ANNOUNCE_SIZE :: 98
UDP_RECV_SIZE     :: 2048

@(private)
UDP_ATTEMPTS :: 2
@(private)
UDP_TIMEOUT  :: 3 * time.Second

announce_udp :: proc(
	url: string,
	req: Announce_Request,
	allocator := context.allocator,
) -> (
	res: Announce_Response,
	err: Error,
) {
	hostport, host_ok := parse_udp_tracker_host(url)
	if !host_ok {
		return {}, Error{kind = .Invalid_Response, message = strings.clone("invalid UDP tracker URL", allocator)}
	}

	ep4, ep6, rerr := net.resolve(hostport)
	if rerr != nil && ep4.address == nil && ep6.address == nil {
		return {}, Error{kind = .Request_Failed, message = strings.clone("could not resolve UDP tracker", allocator)}
	}
	remote := ep4 if ep4.address != nil else ep6
	if remote.address == nil || remote.port == 0 {
		return {}, Error{kind = .Request_Failed, message = strings.clone("UDP tracker missing address or port", allocator)}
	}

	family := net.family_from_endpoint(remote)
	socket, serr := net.make_unbound_udp_socket(family)
	if serr != nil {
		return {}, Error{kind = .Init_Failed, message = strings.clone("could not open UDP socket", allocator)}
	}
	defer net.close(socket)

	if net.set_option(socket, .Receive_Timeout, UDP_TIMEOUT) != nil {
		return {}, Error{kind = .Init_Failed, message = strings.clone("could not set UDP timeout", allocator)}
	}

	connection_id, cerr := udp_connect(socket, remote, allocator)
	if cerr.kind != .None {
		return {}, cerr
	}
	return udp_announce(socket, remote, connection_id, req, allocator)
}

parse_udp_tracker_host :: proc(url: string) -> (hostport: string, ok: bool) {
	if !is_udp_tracker(url) {
		return
	}
	s := url[6:]
	if q := strings.index_byte(s, '?'); q >= 0 {
		s = s[:q]
	}
	if len(s) == 0 {
		return
	}
	if s[0] == '[' {
		end := strings.index_byte(s, ']')
		if end < 0 {
			return
		}
		if slash := strings.index_byte(s[end + 1:], '/'); slash >= 0 {
			s = s[:end + 1 + slash]
		}
		return s, true
	}
	if slash := strings.index_byte(s, '/'); slash >= 0 {
		s = s[:slash]
	}
	if strings.index_byte(s, ':') < 0 {
		return
	}
	return s, true
}

parse_udp_connect_response :: proc(data: []byte, txid: u32, allocator := context.allocator) -> (connection_id: i64, err: Error) {
	if len(data) < 16 {
		return 0, udp_fail(.Invalid_Response, "short UDP connect response", allocator)
	}
	action, _ := endian.get_u32(data[0:], .Big)
	got_txid, _ := endian.get_u32(data[4:], .Big)
	if action == u32(UDP_Action.Error) {
		return 0, udp_error_response(data, txid, allocator)
	}
	if action != u32(UDP_Action.Connect) || got_txid != txid {
		return 0, udp_fail(.Invalid_Response, "UDP connect transaction mismatch", allocator)
	}
	cid, _ := endian.get_i64(data[8:], .Big)
	return cid, {}
}

parse_udp_announce_response :: proc(data: []byte, txid: u32, allocator := context.allocator) -> (res: Announce_Response, err: Error) {
	if len(data) < 20 {
		return {}, udp_fail(.Invalid_Response, "short UDP announce response", allocator)
	}
	action, _ := endian.get_u32(data[0:], .Big)
	got_txid, _ := endian.get_u32(data[4:], .Big)
	if action == u32(UDP_Action.Error) {
		return {}, udp_error_response(data, txid, allocator)
	}
	if action != u32(UDP_Action.Announce) || got_txid != txid {
		return {}, udp_fail(.Invalid_Response, "UDP announce transaction mismatch", allocator)
	}

	interval, _ := endian.get_u32(data[8:], .Big)
	leechers, _ := endian.get_u32(data[12:], .Big)
	seeders, _ := endian.get_u32(data[16:], .Big)
	res.interval = i64(interval)
	res.incomplete = i64(leechers)
	res.complete = i64(seeders)
	res.peers.allocator = allocator
	append_compact_peers(&res.peers, data[20:], false)
	return res, {}
}

@(private)
udp_connect :: proc(socket: net.UDP_Socket, remote: net.Endpoint, allocator := context.allocator) -> (connection_id: i64, err: Error) {
	req: [UDP_CONNECT_SIZE]byte
	endian.put_u64(req[0:], .Big, PROTOCOL_ID)
	endian.put_u32(req[8:], .Big, u32(UDP_Action.Connect))

	for _ in 0 ..< UDP_ATTEMPTS {
		txid := random_u32()
		endian.put_u32(req[12:], .Big, txid)
		if _, send_err := net.send_udp(socket, req[:], remote); send_err != nil {
			err = Error{kind = .Request_Failed, message = strings.clone("UDP connect send failed", allocator)}
			continue
		}
		n, packet, recv_err := udp_recv_matching(socket, remote, txid, u32(UDP_Action.Connect), allocator)
		if recv_err.kind != .None {
			err = recv_err
			continue
		}
		return parse_udp_connect_response(packet[:n], txid, allocator)
	}
	if err.kind == .None {
		err = Error{kind = .Request_Failed, message = strings.clone("UDP connect timed out", allocator)}
	}
	return 0, err
}

@(private)
udp_announce :: proc(
	socket: net.UDP_Socket,
	remote: net.Endpoint,
	connection_id: i64,
	req: Announce_Request,
	allocator := context.allocator,
) -> (
	res: Announce_Response,
	err: Error,
) {
	pkt: [UDP_ANNOUNCE_SIZE]byte
	endian.put_u64(pkt[0:], .Big, u64(connection_id))
	endian.put_u32(pkt[8:], .Big, u32(UDP_Action.Announce))
	info_hash := req.info_hash
	peer_id := req.peer_id
	copy(pkt[16:36], info_hash[:])
	copy(pkt[36:56], peer_id[:])
	endian.put_u64(pkt[56:], .Big, u64(req.downloaded))
	endian.put_u64(pkt[64:], .Big, u64(req.left))
	endian.put_u64(pkt[72:], .Big, u64(req.uploaded))
	endian.put_u32(pkt[80:], .Big, udp_event(req.event))
	endian.put_u32(pkt[84:], .Big, 0)
	endian.put_u32(pkt[88:], .Big, random_u32())
	endian.put_u32(pkt[92:], .Big, 50)
	endian.put_u16(pkt[96:], .Big, req.port)

	for _ in 0 ..< UDP_ATTEMPTS {
		txid := random_u32()
		endian.put_u32(pkt[12:], .Big, txid)
		if _, send_err := net.send_udp(socket, pkt[:], remote); send_err != nil {
			err = Error{kind = .Request_Failed, message = strings.clone("UDP announce send failed", allocator)}
			continue
		}
		n, packet, recv_err := udp_recv_matching(socket, remote, txid, u32(UDP_Action.Announce), allocator)
		if recv_err.kind != .None {
			err = recv_err
			continue
		}
		return parse_udp_announce_response(packet[:n], txid, allocator)
	}
	if err.kind == .None {
		err = Error{kind = .Request_Failed, message = strings.clone("UDP announce timed out", allocator)}
	}
	return {}, err
}

@(private)
udp_recv_matching :: proc(
	socket: net.UDP_Socket,
	remote: net.Endpoint,
	txid: u32,
	want_action: u32,
	allocator := context.allocator,
) -> (
	n: int,
	buf: [UDP_RECV_SIZE]byte,
	err: Error,
) {
	for {
		got, src, recv_err := net.recv_udp(socket, buf[:])
		if recv_err == .Timeout {
			return 0, buf, udp_fail(.Request_Failed, "UDP tracker timed out", allocator)
		}
		if recv_err != nil {
			return 0, buf, udp_fail(.Request_Failed, "UDP tracker receive failed", allocator)
		}
		if !udp_same_endpoint(src, remote) || got < 8 {
			continue
		}
		action, _ := endian.get_u32(buf[0:], .Big)
		got_txid, _ := endian.get_u32(buf[4:], .Big)
		if got_txid != txid {
			continue
		}
		if action != want_action && action != u32(UDP_Action.Error) {
			continue
		}
		return got, buf, {}
	}
}

@(private)
udp_same_endpoint :: proc(a, b: net.Endpoint) -> bool {
	return a.address == b.address && a.port == b.port
}

@(private)
udp_event :: proc(event: Event) -> u32 {
	switch event {
	case .None:
		return 0
	case .Completed:
		return 1
	case .Started:
		return 2
	case .Stopped:
		return 3
	}
	return 0
}

@(private)
udp_error_response :: proc(data: []byte, txid: u32, allocator := context.allocator) -> Error {
	if len(data) >= 8 {
		got_txid, _ := endian.get_u32(data[4:], .Big)
		if got_txid != txid {
			return udp_fail(.Invalid_Response, "UDP error transaction mismatch", allocator)
		}
	}
	msg := "UDP tracker error"
	if len(data) > 8 {
		msg = string(data[8:])
	}
	return udp_fail(.Invalid_Response, msg, allocator)
}

@(private)
udp_fail :: proc(kind: Error_Kind, msg: string, allocator := context.allocator) -> Error {
	return Error{kind = kind, message = strings.clone(msg, allocator)}
}

@(private)
random_u32 :: proc() -> u32 {
	b: [4]byte
	crypto.rand_bytes(b[:])
	v, _ := endian.get_u32(b[:], .Big)
	return v
}
