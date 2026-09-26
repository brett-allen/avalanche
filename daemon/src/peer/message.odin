package peer

import "core:encoding/endian"
import "core:net"

MAX_MESSAGE_SIZE :: 1 << 20

Message :: struct {
	id:         Message_Id,
	payload:    []byte,
	keep_alive: bool,
}

message_destroy :: proc(msg: ^Message, allocator := context.allocator) {
	if msg == nil {
		return
	}
	delete(msg.payload, allocator)
	msg^ = {}
}

encode_message :: proc(msg: Message, allocator := context.allocator) -> (data: []byte, err: Error) {
	if msg.keep_alive {
		return make([]byte, 4, allocator), {}
	}
	length := u32(1 + len(msg.payload))
	data = make([]byte, 4 + int(length), allocator)
	endian.put_u32(data[0:], .Big, length)
	data[4] = u8(msg.id)
	if len(msg.payload) > 0 {
		copy(data[5:], msg.payload)
	}
	return data, {}
}

decode_message :: proc(data: []byte, allocator := context.allocator) -> (msg: Message, err: Error) {
	if len(data) < 4 {
		return {}, peer_fail(.Invalid, "short peer message", allocator)
	}
	length, _ := endian.get_u32(data[0:], .Big)
	if length == 0 {
		if len(data) != 4 {
			return {}, peer_fail(.Invalid, "keep-alive has extra bytes", allocator)
		}
		return Message{keep_alive = true}, {}
	}
	if int(length) > MAX_MESSAGE_SIZE {
		return {}, peer_fail(.Invalid, "peer message too large", allocator)
	}
	if len(data) != 4 + int(length) {
		return {}, peer_fail(.Invalid, "peer message length mismatch", allocator)
	}
	msg.id = Message_Id(data[4])
	if length > 1 {
		msg.payload = make([]byte, int(length) - 1, allocator)
		copy(msg.payload, data[5:])
	}
	return msg, {}
}

read_message :: proc(sock: net.TCP_Socket, allocator := context.allocator) -> (msg: Message, err: Error) {
	header: [4]byte
	if herr := read_all(sock, header[:], allocator); herr.kind != .None {
		return {}, herr
	}
	length, _ := endian.get_u32(header[:], .Big)
	if length == 0 {
		return Message{keep_alive = true}, {}
	}
	if length > MAX_MESSAGE_SIZE {
		return {}, peer_fail(.Invalid, "peer message too large", allocator)
	}
	body := make([]byte, length, allocator)
	if berr := read_all(sock, body, allocator); berr.kind != .None {
		delete(body, allocator)
		return {}, berr
	}
	msg.id = Message_Id(body[0])
	if length > 1 {
		msg.payload = make([]byte, int(length) - 1, allocator)
		copy(msg.payload, body[1:])
	}
	delete(body, allocator)
	return msg, {}
}

write_message :: proc(sock: net.TCP_Socket, msg: Message, allocator := context.allocator) -> Error {
	data, err := encode_message(msg, allocator)
	if err.kind != .None {
		return err
	}
	defer delete(data, allocator)
	return write_all(sock, data, allocator)
}
