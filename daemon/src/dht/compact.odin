package dht

import "core:net"

parse_compact_peers :: proc(data: []byte, allocator := context.allocator) -> []net.Endpoint {
	if len(data) == 0 || len(data) % COMPACT_PEER != 0 {
		return nil
	}
	out: [dynamic]net.Endpoint
	out.allocator = allocator
	for i := 0; i + COMPACT_PEER <= len(data); i += COMPACT_PEER {
		ip := net.IP4_Address{data[i], data[i + 1], data[i + 2], data[i + 3]}
		port := int(data[i + 4]) << 8 | int(data[i + 5])
		// Port 0 is invalid; sub-1024 "peers" are almost always DHT spam.
		if port < 1024 {
			continue
		}
		append(&out, net.Endpoint{address = ip, port = port})
	}
	return out[:]
}

parse_compact_nodes :: proc(data: []byte, allocator := context.allocator) -> []Contact {
	if len(data) < COMPACT_NODE {
		return nil
	}
	n := len(data) / COMPACT_NODE
	out: [dynamic]Contact
	out.allocator = allocator
	for i in 0 ..< n {
		off := i * COMPACT_NODE
		id, ok := id_from_bytes(data[off:off + NODE_ID_SIZE])
		if !ok {
			continue
		}
		base := off + NODE_ID_SIZE
		ip := net.IP4_Address{data[base], data[base + 1], data[base + 2], data[base + 3]}
		port := int(data[base + 4]) << 8 | int(data[base + 5])
		if port == 0 {
			continue
		}
		append(&out, Contact{id = id, endpoint = {address = ip, port = port}})
	}
	return out[:]
}

encode_compact_nodes :: proc(nodes: []Contact, allocator := context.allocator) -> string {
	if len(nodes) == 0 {
		return ""
	}
	buf := make([]byte, len(nodes) * COMPACT_NODE, allocator)
	for n, i in nodes {
		off := i * COMPACT_NODE
		nid := n.id
		copy(buf[off:off + NODE_ID_SIZE], nid[:])
		ip4, ok := n.endpoint.address.(net.IP4_Address)
		if !ok {
			continue
		}
		buf[off + 20] = ip4[0]
		buf[off + 21] = ip4[1]
		buf[off + 22] = ip4[2]
		buf[off + 23] = ip4[3]
		buf[off + 24] = u8(n.endpoint.port >> 8)
		buf[off + 25] = u8(n.endpoint.port)
	}
	return transmute(string)buf
}
