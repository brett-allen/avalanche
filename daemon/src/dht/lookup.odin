package dht

import "core:net"

@(private)
Queried_Set :: map[u64]bool

@(private)
contact_key :: proc(c: Contact) -> u64 {
	ip4, ok := c.endpoint.address.(net.IP4_Address)
	if !ok {
		return 0
	}
	return u64(ip4[0]) << 40 | u64(ip4[1]) << 32 | u64(ip4[2]) << 24 | u64(ip4[3]) << 16 | u64(u16(c.endpoint.port))
}

@(private)
endpoint_key :: proc(ep: net.Endpoint) -> u64 {
	ip4, ok := ep.address.(net.IP4_Address)
	if !ok {
		return 0
	}
	return u64(ip4[0]) << 40 | u64(ip4[1]) << 32 | u64(ip4[2]) << 24 | u64(ip4[3]) << 16 | u64(u16(ep.port))
}

@(private)
merge_contacts :: proc(dst: ^[dynamic]Contact, src: []Contact, target: Node_ID) {
	for c in src {
		exists := false
		for have in dst {
			if have.id == c.id || have.endpoint == c.endpoint {
				exists = true
				break
			}
		}
		if !exists {
			append(dst, c)
		}
	}
	ordered_sort_by_distance(dst[:], target)
	if len(dst) > K * 8 {
		resize(dst, K * 8)
	}
}

@(private)
next_unqueried :: proc(shortlist: []Contact, queried: Queried_Set, n: int) -> []int {
	idxs: [dynamic]int
	idxs.allocator = context.temp_allocator
	for c, i in shortlist {
		if len(idxs) >= n {
			break
		}
		if queried[contact_key(c)] {
			continue
		}
		append(&idxs, i)
	}
	return idxs[:]
}

iterative_find_node :: proc(node: ^Node, target: Node_ID, allocator := context.allocator) -> []Contact {
	shortlist := make([dynamic]Contact, 0, K * 2, allocator)
	defer delete(shortlist)

	seed := routing_closest(&node.table, target, K, allocator)
	merge_contacts(&shortlist, seed, target)
	delete(seed, allocator)

	queried := make(Queried_Set, allocator)
	defer delete(queried)

	for _ in 0 ..< BOOTSTRAP_ROUNDS {
		ordered_sort_by_distance(shortlist[:], target)
		batch := next_unqueried(shortlist[:], queried, ALPHA)
		if len(batch) == 0 {
			break
		}
		for idx in batch {
			c := shortlist[idx]
			queried[contact_key(c)] = true
			nodes, err := rpc_find_node(node, c.endpoint, target, allocator)
			if err.kind != .None {
				if err.message != "" {
					delete(err.message, allocator)
				}
				continue
			}
			if len(nodes) > 0 {
				merge_contacts(&shortlist, nodes, target)
			}
			delete(nodes, allocator)
		}
	}

	out_n := min(K, len(shortlist))
	out := make([]Contact, out_n, allocator)
	copy(out, shortlist[:out_n])
	return out
}

// Token_Hint remembers a get_peers write-token for announce_peer.
Token_Hint :: struct {
	endpoint: net.Endpoint,
	token:    string,
}

iterative_get_peers :: proc(
	node: ^Node,
	info_hash: Node_ID,
	allocator := context.allocator,
) -> (
	peers: []net.Endpoint,
	tokens: []Token_Hint,
	err: Error,
) {
	shortlist := make([dynamic]Contact, 0, K * 2, allocator)
	defer delete(shortlist)

	seed := routing_closest(&node.table, info_hash, K, allocator)
	merge_contacts(&shortlist, seed, info_hash)
	delete(seed, allocator)

	if len(shortlist) == 0 {
		return nil, nil, dht_fail(.Network, "DHT routing table empty", allocator)
	}

	queried := make(Queried_Set, allocator)
	defer delete(queried)

	found := make([dynamic]net.Endpoint, 0, 64, allocator)
	seen_peer := make(map[u64]bool, allocator)
	defer delete(seen_peer)

	hints := make([dynamic]Token_Hint, 0, 16, allocator)

	for _ in 0 ..< LOOKUP_ROUNDS {
		ordered_sort_by_distance(shortlist[:], info_hash)
		batch := next_unqueried(shortlist[:], queried, ALPHA)
		if len(batch) == 0 {
			break
		}
		for idx in batch {
			c := shortlist[idx]
			queried[contact_key(c)] = true

			p, nodes, token, rerr := rpc_get_peers(node, c.endpoint, info_hash, allocator)
			if rerr.kind != .None {
				if rerr.message != "" {
					delete(rerr.message, allocator)
				}
				continue
			}
			for ep in p {
				pk := endpoint_key(ep)
				if !seen_peer[pk] {
					seen_peer[pk] = true
					append(&found, ep)
				}
			}
			delete(p, allocator)
			if len(nodes) > 0 {
				merge_contacts(&shortlist, nodes, info_hash)
			}
			delete(nodes, allocator)
			if token != "" {
				append(&hints, Token_Hint{endpoint = c.endpoint, token = token})
			}
		}
		if len(found) >= 48 {
			break
		}
	}

	return found[:], hints[:], {}
}
