/*
	Peer exchange (BEP 11 / ut_pex).
*/
package peer

import "core:net"
import "core:strings"
import "avalanche:bencode"

UT_PEX :: "ut_pex"

append_pex_peers :: proc(dst: ^[dynamic]net.Endpoint, payload: []byte, allocator := context.allocator) {
	if dst == nil || len(payload) < 2 {
		return
	}
	root, perr := bencode.parse(payload[1:], allocator)
	if perr.kind != .None {
		return
	}
	defer bencode.destroy(&root, allocator)
	dict, ok := bencode.as_dict(root)
	if !ok {
		return
	}
	added, aok := bencode.dict_string(dict, "added")
	if !aok || len(added) == 0 {
		return
	}
	raw := transmute([]u8)added
	if len(raw) % 6 != 0 {
		return
	}
	for i := 0; i + 6 <= len(raw); i += 6 {
		ip := net.IP4_Address{raw[i], raw[i + 1], raw[i + 2], raw[i + 3]}
		port := int(raw[i + 4]) << 8 | int(raw[i + 5])
		if port < 1024 {
			continue
		}
		ep := net.Endpoint{address = ip, port = port}
		exists := false
		for have in dst {
			if have == ep {
				exists = true
				break
			}
		}
		if !exists {
			append(dst, ep)
		}
	}
}

harvest_pex_into :: proc(sock: net.TCP_Socket, ps: ^Peer_Session, allocator := context.allocator) {
	if ps == nil || !ps.got_extended {
		return
	}
	pex_id, has := extension_id(ps.extended, UT_PEX)
	if !has {
		return
	}

	// Nudge peer to send ut_pex.
	{
		root := make(bencode.Dict, allocator)
		root[strings.clone("added", allocator)] = strings.clone("", allocator)
		value := bencode.Value(root)
		enc, eerr := bencode.encode(value, allocator)
		bencode.destroy(&value, allocator)
		if eerr.kind == .None {
			payload := make([]byte, 1 + len(enc), allocator)
			payload[0] = pex_id
			copy(payload[1:], enc)
			delete(enc, allocator)
			_ = write_message(sock, Message{id = .Extended, payload = payload}, allocator)
			delete(payload, allocator)
		}
	}

	for _ in 0 ..< 24 {
		msg, merr := read_message(sock, allocator)
		if merr.kind != .None {
			if merr.message != "" {
				delete(merr.message, allocator)
			}
			break
		}
		if !msg.keep_alive && msg.id == .Extended && len(msg.payload) > 0 {
			if msg.payload[0] == pex_id {
				append_pex_peers(&ps.pex, msg.payload, allocator)
			} else if msg.payload[0] == EXT_HANDSHAKE_ID {
				apply_wire_message(ps, msg, allocator)
			}
		}
		message_destroy(&msg, allocator)
		if len(ps.pex) >= 64 {
			break
		}
	}
}
