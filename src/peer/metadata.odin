/*
	Metadata exchange (BEP 9 / ut_metadata).
*/
package peer

import "core:crypto/hash"
import "core:strings"
import "core:net"
import "avalanche:bencode"

METADATA_PIECE_SIZE :: 16 * 1024
MAX_METADATA_SIZE   :: 4 * 1024 * 1024
MAX_METADATA_MSGS   :: 64

Metadata_Msg :: enum i64 {
	Request = 0,
	Data    = 1,
	Reject  = 2,
}

encode_metadata_request :: proc(peer_msg_id: u8, piece: int, allocator := context.allocator) -> (data: []byte, err: Error) {
	root := make(bencode.Dict, allocator)
	root[strings.clone("msg_type", allocator)] = i64(Metadata_Msg.Request)
	root[strings.clone("piece", allocator)] = i64(piece)
	value := bencode.Value(root)
	defer bencode.destroy(&value, allocator)

	encoded, eerr := bencode.encode(value, allocator)
	if eerr.kind != .None {
		return nil, peer_fail(.Invalid, bencode.error_string(eerr), allocator)
	}
	data = make([]byte, 1 + len(encoded), allocator)
	data[0] = peer_msg_id
	copy(data[1:], encoded)
	delete(encoded, allocator)
	return data, {}
}

decode_metadata_message :: proc(
	payload: []byte,
	allocator := context.allocator,
) -> (
	kind: Metadata_Msg,
	piece: int,
	total_size: i64,
	data: []byte,
	err: Error,
) {
	if len(payload) < 2 {
		return {}, 0, 0, nil, peer_fail(.Invalid, "short ut_metadata message", allocator)
	}
	root, consumed, perr := bencode.parse_prefix(payload[1:], allocator)
	if perr.kind != .None {
		return {}, 0, 0, nil, peer_fail(.Invalid, bencode.error_string(perr), allocator)
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, 0, 0, nil, peer_fail(.Invalid, "ut_metadata payload is not a dict", allocator)
	}
	msg_type, type_ok := bencode.dict_i64(dict, "msg_type")
	piece_n, piece_ok := bencode.dict_i64(dict, "piece")
	if !type_ok || !piece_ok || piece_n < 0 {
		return {}, 0, 0, nil, peer_fail(.Invalid, "ut_metadata missing msg_type/piece", allocator)
	}
	kind = Metadata_Msg(msg_type)
	piece = int(piece_n)
	total_size, _ = bencode.dict_i64(dict, "total_size")
	if kind == .Data {
		data = payload[1 + consumed:]
	}
	return kind, piece, total_size, data, {}
}

@(private)
is_metadata_payload :: proc(payload: []byte, their_id: u8) -> bool {
	if len(payload) == 0 {
		return false
	}
	id := payload[0]
	return id == UT_METADATA_LOCAL_ID || id == their_id
}

@(private)
fetch_metadata :: proc(
	sock: net.TCP_Socket,
	ext: Extended_Handshake,
	want_hash: [20]u8,
	allocator := context.allocator,
) -> (
	raw: []byte,
	ok: bool,
	err: Error,
) {
	their_id, has_id := extension_id(ext, UT_METADATA)
	if !has_id {
		return nil, false, {}
	}

	size := ext.metadata_size
	if size < 0 || size > MAX_METADATA_SIZE {
		return nil, false, peer_fail(.Invalid, "ut_metadata size is implausible", allocator)
	}

	if size == 0 {
		if rerr := send_metadata_request(sock, their_id, 0, allocator); rerr.kind != .None {
			return nil, false, rerr
		}
		kind, piece, total, data, merr := wait_metadata_data(sock, their_id, allocator)
		_ = kind
		_ = piece
		if merr.kind != .None {
			return nil, false, merr
		}
		if total <= 0 || total > MAX_METADATA_SIZE {
			delete(data, allocator)
			return nil, false, peer_fail(.Invalid, "ut_metadata total_size missing", allocator)
		}
		size = total
		raw = make([]byte, int(size), allocator)
		if !copy_metadata_piece(raw, 0, data, size) {
			delete(data, allocator)
			delete(raw, allocator)
			return nil, false, peer_fail(.Invalid, "ut_metadata piece 0 overflow", allocator)
		}
		delete(data, allocator)
		if size <= METADATA_PIECE_SIZE {
			return finish_metadata(raw, want_hash, allocator)
		}
		for i := 1; i < metadata_piece_count(size); i += 1 {
			if rerr := send_metadata_request(sock, their_id, i, allocator); rerr.kind != .None {
				delete(raw, allocator)
				return nil, false, rerr
			}
		}
		got := 1
		for got < metadata_piece_count(size) {
			k, p, _, pdata, werr := wait_metadata_data(sock, their_id, allocator)
			_ = k
			if werr.kind != .None {
				delete(raw, allocator)
				return nil, false, werr
			}
			if !copy_metadata_piece(raw, p, pdata, size) {
				delete(pdata, allocator)
				delete(raw, allocator)
				return nil, false, peer_fail(.Invalid, "ut_metadata piece overflow", allocator)
			}
			delete(pdata, allocator)
			got += 1
		}
		return finish_metadata(raw, want_hash, allocator)
	}

	raw = make([]byte, int(size), allocator)
	count := metadata_piece_count(size)
	for i in 0 ..< count {
		if rerr := send_metadata_request(sock, their_id, i, allocator); rerr.kind != .None {
			delete(raw, allocator)
			return nil, false, rerr
		}
	}

	received := make([]bool, count, context.temp_allocator)
	got := 0
	for got < count {
		kind, piece, _, data, werr := wait_metadata_data(sock, their_id, allocator)
		_ = kind
		if werr.kind != .None {
			delete(raw, allocator)
			return nil, false, werr
		}
		if piece < 0 || piece >= count || received[piece] {
			delete(data, allocator)
			continue
		}
		if !copy_metadata_piece(raw, piece, data, size) {
			delete(data, allocator)
			delete(raw, allocator)
			return nil, false, peer_fail(.Invalid, "ut_metadata piece overflow", allocator)
		}
		delete(data, allocator)
		received[piece] = true
		got += 1
	}
	return finish_metadata(raw, want_hash, allocator)
}

@(private)
metadata_piece_count :: proc(size: i64) -> int {
	return int((size + METADATA_PIECE_SIZE - 1) / METADATA_PIECE_SIZE)
}

@(private)
send_metadata_request :: proc(sock: net.TCP_Socket, their_id: u8, piece: int, allocator := context.allocator) -> Error {
	payload, err := encode_metadata_request(their_id, piece, allocator)
	if err.kind != .None {
		return err
	}
	defer delete(payload, allocator)
	return write_message(sock, Message{id = .Extended, payload = payload}, allocator)
}

@(private)
wait_metadata_data :: proc(
	sock: net.TCP_Socket,
	their_id: u8,
	allocator := context.allocator,
) -> (
	kind: Metadata_Msg,
	piece: int,
	total_size: i64,
	data: []byte,
	err: Error,
) {
	for _ in 0 ..< MAX_METADATA_MSGS {
		msg, merr := read_message(sock, allocator)
		if merr.kind != .None {
			return {}, 0, 0, nil, merr
		}
		if msg.keep_alive || msg.id != .Extended || !is_metadata_payload(msg.payload, their_id) {
			message_destroy(&msg, allocator)
			continue
		}
		kind, piece, total_size, view, derr := decode_metadata_message(msg.payload, allocator)
		owned: []byte
		if derr.kind == .None && kind == .Data && len(view) > 0 {
			owned = make([]byte, len(view), allocator)
			copy(owned, view)
		}
		message_destroy(&msg, allocator)
		if derr.kind != .None {
			return {}, 0, 0, nil, derr
		}
		if kind == .Reject {
			delete(owned, allocator)
			return {}, 0, 0, nil, peer_fail(.Protocol, "peer rejected ut_metadata request", allocator)
		}
		if kind == .Request {
			delete(owned, allocator)
			continue
		}
		if kind == .Data {
			return kind, piece, total_size, owned, {}
		}
		delete(owned, allocator)
	}
	return {}, 0, 0, nil, peer_fail(.Timeout, "timed out waiting for ut_metadata", allocator)
}

@(private)
copy_metadata_piece :: proc(raw: []byte, piece: int, data: []byte, total: i64) -> bool {
	start := piece * METADATA_PIECE_SIZE
	if start >= int(total) {
		return false
	}
	want := METADATA_PIECE_SIZE
	if start + want > int(total) {
		want = int(total) - start
	}
	if len(data) < want {
		want = len(data)
	}
	if start + want > len(raw) {
		return false
	}
	copy(raw[start:], data[:want])
	return true
}

@(private)
finish_metadata :: proc(raw: []byte, want_hash: [20]u8, allocator := context.allocator) -> ([]byte, bool, Error) {
	digest: [20]u8
	hash.hash(.Insecure_SHA1, raw, digest[:])
	if digest != want_hash {
		delete(raw, allocator)
		return nil, false, peer_fail(.Protocol, "ut_metadata infohash mismatch", allocator)
	}
	return raw, true, {}
}
