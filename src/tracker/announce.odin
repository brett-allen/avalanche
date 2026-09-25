package tracker

import "core:net"
import "core:strings"
import "avalanche:bencode"

parse_announce_body :: proc(data: []byte, allocator := context.allocator) -> (res: Announce_Response, err: Error) {
	root, perr := bencode.parse(data, allocator)
	if perr.kind != .None {
		return {}, Error{kind = .Invalid_Response, message = bencode.error_string(perr)}
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, Error{kind = .Invalid_Response, message = "announce response is not a dict"}
	}

	if reason, ok := bencode.dict_string(dict, "failure reason"); ok {
		return {}, Error{kind = .Invalid_Response, message = strings.clone(reason, allocator)}
	}

	res.interval, _ = bencode.dict_i64(dict, "interval")
	res.min_interval, _ = bencode.dict_i64(dict, "min interval")
	res.complete, _ = bencode.dict_i64(dict, "complete")
	res.incomplete, _ = bencode.dict_i64(dict, "incomplete")
	res.peers.allocator = allocator

	if peers, ok := bencode.dict_get(dict, "peers"); ok {
		append_peers(&res.peers, peers, false)
	}
	if peers6, ok := bencode.dict_get(dict, "peers6"); ok {
		append_peers(&res.peers, peers6, true)
	}
	return res, {}
}

@(private)
append_peers :: proc(out: ^[dynamic]Peer_Addr, value: bencode.Value, ipv6: bool) {
	if compact, ok := bencode.as_string(value); ok {
		append_compact_peers(out, transmute([]byte)compact, ipv6)
		return
	}
	list, list_ok := bencode.as_list(value)
	if !list_ok {
		return
	}
	for item in list {
		dict, dict_ok := bencode.as_dict(item)
		if !dict_ok {
			continue
		}
		ip, ip_ok := bencode.dict_string(dict, "ip")
		port_n, port_ok := bencode.dict_i64(dict, "port")
		if !ip_ok || !port_ok || port_n < 0 || port_n > 65535 {
			continue
		}
		addr := net.parse_address(ip)
		if addr == nil {
			continue
		}
		append(out, Peer_Addr{endpoint = {address = addr, port = int(port_n)}})
	}
}

@(private)
append_compact_peers :: proc(out: ^[dynamic]Peer_Addr, data: []byte, ipv6: bool) {
	stride := 18 if ipv6 else 6
	if len(data) % stride != 0 {
		return
	}
	for i := 0; i < len(data); i += stride {
		if ipv6 {
			words: [8]u16be
			for w in 0 ..< 8 {
				hi := data[i + 2 * w]
				lo := data[i + 2 * w + 1]
				words[w] = u16be(u16(hi) << 8 | u16(lo))
			}
			port := int(data[i + 16]) << 8 | int(data[i + 17])
			append(out, Peer_Addr{endpoint = {address = net.IP6_Address(words), port = port}})
		} else {
			ip := net.IP4_Address{data[i], data[i + 1], data[i + 2], data[i + 3]}
			port := int(data[i + 4]) << 8 | int(data[i + 5])
			append(out, Peer_Addr{endpoint = {address = ip, port = port}})
		}
	}
}

is_http_tracker :: proc(url: string) -> bool {
	return has_prefix_ci(url, "http://") || has_prefix_ci(url, "https://")
}

has_prefix_ci :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		a := s[i]
		b := prefix[i]
		if a >= 'A' && a <= 'Z' {
			a += 32
		}
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		if a != b {
			return false
		}
	}
	return true
}
