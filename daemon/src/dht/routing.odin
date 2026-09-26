package dht

import "core:mem"
import "core:sync"

MAX_TABLE :: 512

// Flat routing table of known good contacts. Sorted inserts by distance to self
// keep us useful for bootstrap/get_peers without full k-bucket splitting yet.
Routing_Table :: struct {
	self_id:   Node_ID,
	mu:        sync.Mutex,
	contacts:  [dynamic]Contact,
	allocator: mem.Allocator,
}

routing_init :: proc(t: ^Routing_Table, self_id: Node_ID, allocator := context.allocator) {
	t.self_id = self_id
	t.allocator = allocator
	t.contacts = make([dynamic]Contact, 0, 64, allocator)
}

routing_destroy :: proc(t: ^Routing_Table) {
	if t == nil {
		return
	}
	delete(t.contacts)
	t^ = {}
}

routing_count :: proc(t: ^Routing_Table) -> int {
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)
	return len(t.contacts)
}

routing_insert :: proc(t: ^Routing_Table, c: Contact) {
	if c.endpoint.address == nil || c.endpoint.port == 0 {
		return
	}
	if c.id == t.self_id {
		return
	}
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)

	for &have in t.contacts {
		if have.id == c.id || have.endpoint == c.endpoint {
			have = c
			return
		}
	}
	append(&t.contacts, c)
	if len(t.contacts) > MAX_TABLE {
		ordered_sort_by_distance(t.contacts[:], t.self_id)
		resize(&t.contacts, MAX_TABLE)
	}
}

routing_closest :: proc(t: ^Routing_Table, target: Node_ID, n: int, allocator := context.allocator) -> []Contact {
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)
	if len(t.contacts) == 0 || n <= 0 {
		return nil
	}
	tmp := make([]Contact, len(t.contacts), context.temp_allocator)
	copy(tmp, t.contacts[:])
	ordered_sort_by_distance(tmp, target)
	count := min(n, len(tmp))
	out := make([]Contact, count, allocator)
	copy(out, tmp[:count])
	return out
}

@(private)
ordered_sort_by_distance :: proc(nodes: []Contact, target: Node_ID) {
	for i in 1 ..< len(nodes) {
		key := nodes[i]
		j := i - 1
		for j >= 0 && closer(key.id, nodes[j].id, target) {
			nodes[j + 1] = nodes[j]
			j -= 1
		}
		nodes[j + 1] = key
	}
}
