package dht

import "core:net"
import "core:sync"
import "core:time"
import "avalanche:bencode"

@(private)
next_tid :: proc(node: ^Node) -> u16 {
	node.tid += 1
	if node.tid == 0 {
		node.tid = 1
	}
	return node.tid
}

@(private)
rpc_call :: proc(
	node: ^Node,
	remote: net.Endpoint,
	kind: Query_Kind,
	target: Node_ID = {},
	info_hash: Node_ID = {},
	allocator := context.allocator,
) -> (
	resp: Parsed_Response,
	err: Error,
) {
	sync.lock(&node.mu)
	defer sync.unlock(&node.mu)

	tid := next_tid(node)
	payload, perr := build_query(tid, kind, node.id, target, info_hash, allocator = allocator)
	if perr.kind != .None {
		return {}, perr
	}
	defer delete(payload, allocator)

	if _, serr := net.send_udp(node.sock, payload, remote); serr != nil {
		return {}, dht_fail(.Network, "DHT send failed", allocator)
	}

	deadline := time.tick_now()
	buf: [2048]byte
	for time.tick_since(deadline) < RPC_TIMEOUT {
		n, source, rerr := net.recv_udp(node.sock, buf[:])
		if rerr != nil || n <= 0 {
			continue
		}
		msg, is_query, merr := parse_message(buf[:n], allocator)
		if merr.kind != .None {
			if merr.message != "" {
				delete(merr.message, allocator)
			}
			continue
		}
		if is_query {
			handle_inbound_query(node, buf[:n], source, allocator)
			continue
		}
		if !msg.ok || msg.tid != tid {
			if msg.has_token {
				delete(msg.token, allocator)
			}
			delete(msg.nodes, allocator)
			delete(msg.peers, allocator)
			continue
		}
		if msg.id != (Node_ID{}) {
			routing_insert(&node.table, Contact{id = msg.id, endpoint = source})
		}
		for c in msg.nodes {
			routing_insert(&node.table, c)
		}
		return msg, {}
	}
	return {}, dht_fail(.Timeout, "DHT RPC timeout", allocator)
}

rpc_ping :: proc(node: ^Node, remote: net.Endpoint, allocator := context.allocator) -> Error {
	resp, err := rpc_call(node, remote, .Ping, allocator = allocator)
	if err.kind != .None {
		return err
	}
	if resp.has_token {
		delete(resp.token, allocator)
	}
	delete(resp.nodes, allocator)
	delete(resp.peers, allocator)
	return {}
}

rpc_find_node :: proc(
	node: ^Node,
	remote: net.Endpoint,
	target: Node_ID,
	allocator := context.allocator,
) -> (
	nodes: []Contact,
	err: Error,
) {
	resp, rerr := rpc_call(node, remote, .Find_Node, target = target, allocator = allocator)
	if rerr.kind != .None {
		return nil, rerr
	}
	if resp.has_token {
		delete(resp.token, allocator)
	}
	delete(resp.peers, allocator)
	return resp.nodes, {}
}

rpc_get_peers :: proc(
	node: ^Node,
	remote: net.Endpoint,
	info_hash: Node_ID,
	allocator := context.allocator,
) -> (
	peers: []net.Endpoint,
	nodes: []Contact,
	token: string,
	err: Error,
) {
	resp, rerr := rpc_call(node, remote, .Get_Peers, info_hash = info_hash, allocator = allocator)
	if rerr.kind != .None {
		return nil, nil, "", rerr
	}
	return resp.peers, resp.nodes, resp.token if resp.has_token else "", {}
}

rpc_announce_peer :: proc(
	node: ^Node,
	remote: net.Endpoint,
	info_hash: Node_ID,
	token: string,
	port: u16,
	allocator := context.allocator,
) -> Error {
	sync.lock(&node.mu)
	defer sync.unlock(&node.mu)

	tid := next_tid(node)
	payload, perr := build_query(
		tid,
		.Announce_Peer,
		node.id,
		info_hash = info_hash,
		token = token,
		port = i64(port),
		allocator = allocator,
	)
	if perr.kind != .None {
		return perr
	}
	defer delete(payload, allocator)

	if _, serr := net.send_udp(node.sock, payload, remote); serr != nil {
		return dht_fail(.Network, "DHT announce_peer send failed", allocator)
	}

	deadline := time.tick_now()
	buf: [2048]byte
	for time.tick_since(deadline) < RPC_TIMEOUT {
		n, source, rerr := net.recv_udp(node.sock, buf[:])
		if rerr != nil || n <= 0 {
			continue
		}
		msg, is_query, merr := parse_message(buf[:n], allocator)
		if merr.kind != .None {
			if merr.message != "" {
				delete(merr.message, allocator)
			}
			continue
		}
		if is_query {
			handle_inbound_query(node, buf[:n], source, allocator)
			continue
		}
		if !msg.ok || msg.tid != tid {
			if msg.has_token {
				delete(msg.token, allocator)
			}
			delete(msg.nodes, allocator)
			delete(msg.peers, allocator)
			continue
		}
		if msg.has_token {
			delete(msg.token, allocator)
		}
		delete(msg.nodes, allocator)
		delete(msg.peers, allocator)
		return {}
	}
	return dht_fail(.Timeout, "DHT announce_peer timeout", allocator)
}

// rpc_announce_peer_noreply sends announce_peer and does not wait for a reply.
rpc_announce_peer_noreply :: proc(
	node: ^Node,
	remote: net.Endpoint,
	info_hash: Node_ID,
	token: string,
	port: u16,
	allocator := context.allocator,
) -> Error {
	sync.lock(&node.mu)
	defer sync.unlock(&node.mu)

	tid := next_tid(node)
	payload, perr := build_query(
		tid,
		.Announce_Peer,
		node.id,
		info_hash = info_hash,
		token = token,
		port = i64(port),
		allocator = allocator,
	)
	if perr.kind != .None {
		return perr
	}
	defer delete(payload, allocator)
	if _, serr := net.send_udp(node.sock, payload, remote); serr != nil {
		return dht_fail(.Network, "DHT announce_peer send failed", allocator)
	}
	return {}
}

@(private)
handle_inbound_query :: proc(node: ^Node, data: []byte, source: net.Endpoint, allocator := context.allocator) {
	root, perr := bencode.parse(data, allocator)
	if perr.kind != .None {
		return
	}
	defer bencode.destroy(&root, allocator)
	dict, ok := bencode.as_dict(root)
	if !ok {
		return
	}
	y, _ := bencode.dict_string(dict, "y")
	if y != "q" {
		return
	}
	q, _ := bencode.dict_string(dict, "q")
	t, _ := bencode.dict_string(dict, "t")
	if q == "ping" && t != "" {
		out, oerr := build_ping_response(t, node.id, allocator)
		if oerr.kind == .None {
			_, _ = net.send_udp(node.sock, out, source)
			delete(out, allocator)
		} else if oerr.message != "" {
			delete(oerr.message, allocator)
		}
	}
	// Register querier if present.
	if a_val, a_ok := bencode.dict_get(dict, "a"); a_ok {
		if a, ad_ok := bencode.as_dict(a_val); ad_ok {
			if id_s, id_ok := bencode.dict_string(a, "id"); id_ok {
				if id, iok := id_from_bytes(transmute([]u8)id_s); iok {
					routing_insert(&node.table, Contact{id = id, endpoint = source})
				}
			}
		}
	}
}
