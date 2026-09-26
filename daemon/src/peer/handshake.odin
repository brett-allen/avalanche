package peer

import "core:encoding/hex"
import "core:strings"

HANDSHAKE_SIZE :: 68
PROTOCOL_LEN   :: 19

// BEP 10: reserved bit 20 from the right (reserved[5] & 0x10).
EXTENSION_RESERVED_BYTE :: 5
EXTENSION_RESERVED_BIT  :: u8(0x10)

// BEP 5: last bit of the reserved string marks DHT support.
DHT_RESERVED_BYTE :: 7
DHT_RESERVED_BIT  :: u8(0x01)

encode_handshake :: proc(hs: Handshake, allocator := context.allocator) -> (data: []byte, err: Error) {
	if len(PROTOCOL) != PROTOCOL_LEN {
		return nil, peer_fail(.Invalid, "internal protocol length mismatch", allocator)
	}
	data = make([]byte, HANDSHAKE_SIZE, allocator)
	data[0] = u8(PROTOCOL_LEN)
	copy(data[1:20], transmute([]u8)string(PROTOCOL))
	reserved := hs.reserved
	info_hash := hs.info_hash
	peer_id := hs.peer_id
	copy(data[20:28], reserved[:])
	copy(data[28:48], info_hash[:])
	copy(data[48:68], peer_id[:])
	return data, {}
}

decode_handshake :: proc(data: []byte, allocator := context.allocator) -> (hs: Handshake, err: Error) {
	if len(data) < HANDSHAKE_SIZE {
		return {}, peer_fail(.Invalid, "short handshake", allocator)
	}
	if data[0] != u8(PROTOCOL_LEN) {
		return {}, peer_fail(.Protocol, "unexpected handshake pstrlen", allocator)
	}
	if string(data[1:20]) != PROTOCOL {
		return {}, peer_fail(.Protocol, "unexpected handshake protocol", allocator)
	}
	copy(hs.reserved[:], data[20:28])
	copy(hs.info_hash[:], data[28:48])
	copy(hs.peer_id[:], data[48:68])
	return hs, {}
}

make_handshake :: proc(info_hash, peer_id: [20]u8) -> (hs: Handshake) {
	hs.info_hash = info_hash
	hs.peer_id = peer_id
	set_extension(&hs)
	set_dht(&hs)
	return
}

set_extension :: proc(hs: ^Handshake) {
	hs.reserved[EXTENSION_RESERVED_BYTE] |= EXTENSION_RESERVED_BIT
}

has_extension :: proc(hs: Handshake) -> bool {
	return hs.reserved[EXTENSION_RESERVED_BYTE] & EXTENSION_RESERVED_BIT != 0
}

set_dht :: proc(hs: ^Handshake) {
	hs.reserved[DHT_RESERVED_BYTE] |= DHT_RESERVED_BIT
}

has_dht :: proc(hs: Handshake) -> bool {
	return hs.reserved[DHT_RESERVED_BYTE] & DHT_RESERVED_BIT != 0
}

peer_id_hex :: proc(id: [20]u8, allocator := context.allocator) -> string {
	bytes := id
	encoded, _ := hex.encode(bytes[:], allocator)
	return string(encoded)
}

peer_id_label :: proc(id: [20]u8, allocator := context.allocator) -> string {
	printable := true
	for b in id {
		if b < 32 || b > 126 {
			printable = false
			break
		}
	}
	if printable {
		bytes := id
		return strings.clone(string(bytes[:]), allocator)
	}
	return peer_id_hex(id, allocator)
}

@(private)
peer_fail :: proc(kind: Error_Kind, msg: string, allocator := context.allocator) -> Error {
	return Error{kind = kind, message = strings.clone(msg, allocator)}
}
