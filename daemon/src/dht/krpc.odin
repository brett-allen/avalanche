package dht

import "core:encoding/endian"
import "core:net"
import "core:strings"
import "avalanche:bencode"

Query_Kind :: enum {
	Ping,
	Find_Node,
	Get_Peers,
	Announce_Peer,
}

Parsed_Response :: struct {
	tid:       u16,
	id:        Node_ID,
	nodes:     []Contact,
	peers:     []net.Endpoint,
	token:     string,
	has_token: bool,
	ok:        bool,
}

@(private)
dict_put :: proc(d: ^bencode.Dict, key: string, value: bencode.Value, allocator := context.allocator) {
	d^[strings.clone(key, allocator)] = value
}

build_query :: proc(
	tid: u16,
	kind: Query_Kind,
	self_id: Node_ID,
	target: Node_ID = {},
	info_hash: Node_ID = {},
	token: string = "",
	port: i64 = 0,
	allocator := context.allocator,
) -> (
	data: []byte,
	err: Error,
) {
	tid_buf: [2]u8
	endian.put_u16(tid_buf[:], .Big, tid)
	tid_s, _ := strings.clone_from_bytes(tid_buf[:], allocator)

	args: bencode.Dict
	args = make(bencode.Dict, allocator)
	dict_put(&args, "id", id_bytes(self_id, allocator), allocator)

	qname: string
	switch kind {
	case .Ping:
		qname = strings.clone("ping", allocator)
	case .Find_Node:
		qname = strings.clone("find_node", allocator)
		dict_put(&args, "target", id_bytes(target, allocator), allocator)
	case .Get_Peers:
		qname = strings.clone("get_peers", allocator)
		dict_put(&args, "info_hash", id_bytes(info_hash, allocator), allocator)
	case .Announce_Peer:
		qname = strings.clone("announce_peer", allocator)
		dict_put(&args, "info_hash", id_bytes(info_hash, allocator), allocator)
		dict_put(&args, "port", port, allocator)
		dict_put(&args, "token", strings.clone(token, allocator), allocator)
		dict_put(&args, "implied_port", i64(0), allocator)
	}

	root: bencode.Dict
	root = make(bencode.Dict, allocator)
	dict_put(&root, "t", tid_s, allocator)
	dict_put(&root, "y", strings.clone("q", allocator), allocator)
	dict_put(&root, "q", qname, allocator)
	dict_put(&root, "a", args, allocator)
	dict_put(&root, "v", strings.clone("AV01", allocator), allocator)

	value: bencode.Value = root
	defer bencode.destroy(&value, allocator)

	encoded, eerr := bencode.encode(value, allocator)
	if eerr.kind != .None {
		return nil, dht_fail(.Protocol, bencode.error_string(eerr), allocator)
	}
	return encoded, {}
}

parse_message :: proc(data: []byte, allocator := context.allocator) -> (msg: Parsed_Response, is_query: bool, err: Error) {
	root, perr := bencode.parse(data, allocator)
	if perr.kind != .None {
		return {}, false, dht_fail(.Protocol, bencode.error_string(perr), allocator)
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, false, dht_fail(.Protocol, "DHT message is not a dict", allocator)
	}

	y, yok := bencode.dict_string(dict, "y")
	if !yok || len(y) == 0 {
		return {}, false, dht_fail(.Protocol, "DHT message missing y", allocator)
	}

	if t, tok := bencode.dict_string(dict, "t"); tok {
		tb := transmute([]u8)t
		if len(tb) >= 2 {
			msg.tid, _ = endian.get_u16(tb, .Big)
		} else if len(tb) == 1 {
			msg.tid = u16(tb[0])
		}
	}

	if y == "q" {
		return msg, true, {}
	}
	if y == "e" {
		return {}, false, dht_fail(.Protocol, "DHT error response", allocator)
	}
	if y != "r" {
		return {}, false, dht_fail(.Protocol, "unknown DHT message type", allocator)
	}

	r_val, r_ok := bencode.dict_get(dict, "r")
	if !r_ok {
		return {}, false, dht_fail(.Protocol, "DHT response missing r", allocator)
	}
	r, rd_ok := bencode.as_dict(r_val)
	if !rd_ok {
		return {}, false, dht_fail(.Protocol, "DHT r is not a dict", allocator)
	}

	if id_s, id_ok := bencode.dict_string(r, "id"); id_ok {
		msg.id, _ = id_from_bytes(transmute([]u8)id_s)
	}
	if nodes_s, n_ok := bencode.dict_string(r, "nodes"); n_ok {
		msg.nodes = parse_compact_nodes(transmute([]u8)nodes_s, allocator)
	}
	if token, t_ok := bencode.dict_string(r, "token"); t_ok {
		msg.token = strings.clone(token, allocator)
		msg.has_token = true
	}
	if values, v_ok := bencode.dict_get(r, "values"); v_ok {
		if list, l_ok := bencode.as_list(values); l_ok {
			peers: [dynamic]net.Endpoint
			peers.allocator = allocator
			for item in list {
				if s, s_ok := bencode.as_string(item); s_ok {
					eps := parse_compact_peers(transmute([]u8)s, context.temp_allocator)
					for ep in eps {
						append(&peers, ep)
					}
				}
			}
			msg.peers = peers[:]
		} else if s, s_ok := bencode.as_string(values); s_ok {
			msg.peers = parse_compact_peers(transmute([]u8)s, allocator)
		}
	}
	msg.ok = true
	return msg, false, {}
}

build_ping_response :: proc(tid_raw: string, self_id: Node_ID, allocator := context.allocator) -> ([]byte, Error) {
	root: bencode.Dict = make(bencode.Dict, allocator)
	dict_put(&root, "t", strings.clone(tid_raw, allocator), allocator)
	dict_put(&root, "y", strings.clone("r", allocator), allocator)
	r: bencode.Dict = make(bencode.Dict, allocator)
	dict_put(&r, "id", id_bytes(self_id, allocator), allocator)
	dict_put(&root, "r", r, allocator)
	value: bencode.Value = root
	defer bencode.destroy(&value, allocator)
	encoded, eerr := bencode.encode(value, allocator)
	if eerr.kind != .None {
		return nil, dht_fail(.Protocol, bencode.error_string(eerr), allocator)
	}
	return encoded, {}
}
