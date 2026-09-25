package peer

import "core:encoding/endian"
import "core:net"

BLOCK_SIZE      :: 16 * 1024
MAX_PIPELINE    :: 8
DOWNLOAD_MSGS   :: 256

Bitfield :: struct {
	bits:  []byte,
	count: int,
}

bitfield_make :: proc(piece_count: int, allocator := context.allocator) -> Bitfield {
	nbytes := (piece_count + 7) / 8
	return Bitfield{
		bits  = make([]byte, nbytes, allocator),
		count = piece_count,
	}
}

bitfield_destroy :: proc(bf: ^Bitfield, allocator := context.allocator) {
	if bf == nil {
		return
	}
	delete(bf.bits, allocator)
	bf^ = {}
}

bitfield_has :: proc(bf: Bitfield, index: int) -> bool {
	if index < 0 || index >= bf.count || len(bf.bits) == 0 {
		return false
	}
	return bf.bits[index / 8] & (0x80 >> uint(index % 8)) != 0
}

bitfield_set :: proc(bf: ^Bitfield, index: int) {
	if bf == nil || index < 0 || index >= bf.count {
		return
	}
	bf.bits[index / 8] |= 0x80 >> uint(index % 8)
}

bitfield_from_bytes :: proc(data: []byte, piece_count: int, allocator := context.allocator) -> Bitfield {
	bf := bitfield_make(piece_count, allocator)
	n := min(len(data), len(bf.bits))
	copy(bf.bits, data[:n])
	return bf
}

encode_interested :: proc(allocator := context.allocator) -> ([]byte, Error) {
	return encode_message(Message{id = .Interested}, allocator)
}

encode_not_interested :: proc(allocator := context.allocator) -> ([]byte, Error) {
	return encode_message(Message{id = .Not_Interested}, allocator)
}

encode_choke :: proc(allocator := context.allocator) -> ([]byte, Error) {
	return encode_message(Message{id = .Choke}, allocator)
}

encode_unchoke :: proc(allocator := context.allocator) -> ([]byte, Error) {
	return encode_message(Message{id = .Unchoke}, allocator)
}

encode_have :: proc(index: u32, allocator := context.allocator) -> ([]byte, Error) {
	payload := make([]byte, 4, allocator)
	endian.put_u32(payload, .Big, index)
	defer delete(payload, allocator)
	return encode_message(Message{id = .Have, payload = payload}, allocator)
}

encode_request :: proc(index, begin, length: u32, allocator := context.allocator) -> ([]byte, Error) {
	payload := make([]byte, 12, allocator)
	endian.put_u32(payload[0:], .Big, index)
	endian.put_u32(payload[4:], .Big, begin)
	endian.put_u32(payload[8:], .Big, length)
	defer delete(payload, allocator)
	return encode_message(Message{id = .Request, payload = payload}, allocator)
}

decode_have :: proc(payload: []byte) -> (index: u32, ok: bool) {
	if len(payload) != 4 {
		return 0, false
	}
	index, _ = endian.get_u32(payload, .Big)
	return index, true
}

decode_request_fields :: proc(payload: []byte) -> (index, begin, length: u32, ok: bool) {
	if len(payload) != 12 {
		return 0, 0, 0, false
	}
	index, _ = endian.get_u32(payload[0:], .Big)
	begin, _ = endian.get_u32(payload[4:], .Big)
	length, _ = endian.get_u32(payload[8:], .Big)
	return index, begin, length, true
}

decode_piece :: proc(payload: []byte) -> (index, begin: u32, block: []byte, ok: bool) {
	if len(payload) < 8 {
		return 0, 0, nil, false
	}
	index, _ = endian.get_u32(payload[0:], .Big)
	begin, _ = endian.get_u32(payload[4:], .Big)
	block = payload[8:]
	return index, begin, block, true
}

write_id :: proc(sock: net.TCP_Socket, id: Message_Id, allocator := context.allocator) -> Error {
	return write_message(sock, Message{id = id}, allocator)
}

write_request :: proc(sock: net.TCP_Socket, index, begin, length: u32, allocator := context.allocator) -> Error {
	payload: [12]byte
	endian.put_u32(payload[0:], .Big, index)
	endian.put_u32(payload[4:], .Big, begin)
	endian.put_u32(payload[8:], .Big, length)
	return write_message(sock, Message{id = .Request, payload = payload[:]}, allocator)
}

write_have :: proc(sock: net.TCP_Socket, index: u32, allocator := context.allocator) -> Error {
	payload: [4]byte
	endian.put_u32(payload[:], .Big, index)
	return write_message(sock, Message{id = .Have, payload = payload[:]}, allocator)
}
