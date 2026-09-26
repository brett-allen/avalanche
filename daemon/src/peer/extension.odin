/*
	Extension protocol (BEP 10).
*/
package peer

import "core:strings"
import "avalanche:bencode"

EXT_HANDSHAKE_ID     :: u8(0)
UT_METADATA          :: "ut_metadata"
UT_METADATA_LOCAL_ID :: u8(1)
CLIENT_VERSION       :: "Avalanche/0.1"

MAX_SKIP_MESSAGES :: 16

Extended_Handshake :: struct {
	messages:      map[string]u8,
	client:        string,
	port:          i64,
	metadata_size: i64,
	reqq:          i64,
	yourip:        []byte,
}

extended_destroy :: proc(ext: ^Extended_Handshake, allocator := context.allocator) {
	if ext == nil {
		return
	}
	for key in ext.messages {
		delete(key, allocator)
	}
	delete(ext.messages)
	delete(ext.client, allocator)
	delete(ext.yourip, allocator)
	ext^ = {}
}

encode_extended_handshake :: proc(port: u16, allocator := context.allocator) -> (data: []byte, err: Error) {
	m := make(bencode.Dict, allocator)
	m[strings.clone(UT_METADATA, allocator)] = i64(UT_METADATA_LOCAL_ID)

	root := make(bencode.Dict, allocator)
	root[strings.clone("m", allocator)] = m
	root[strings.clone("v", allocator)] = strings.clone(CLIENT_VERSION, allocator)
	if port != 0 {
		root[strings.clone("p", allocator)] = i64(port)
	}

	value := bencode.Value(root)
	defer bencode.destroy(&value, allocator)

	encoded, eerr := bencode.encode(value, allocator)
	if eerr.kind != .None {
		return nil, peer_fail(.Invalid, bencode.error_string(eerr), allocator)
	}

	data = make([]byte, 1 + len(encoded), allocator)
	data[0] = EXT_HANDSHAKE_ID
	copy(data[1:], encoded)
	delete(encoded, allocator)
	return data, {}
}

decode_extended_handshake :: proc(payload: []byte, allocator := context.allocator) -> (ext: Extended_Handshake, err: Error) {
	if len(payload) < 1 || payload[0] != EXT_HANDSHAKE_ID {
		return {}, peer_fail(.Protocol, "not an extension handshake", allocator)
	}

	root, perr := bencode.parse(payload[1:], allocator)
	if perr.kind != .None {
		return {}, peer_fail(.Invalid, bencode.error_string(perr), allocator)
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, peer_fail(.Invalid, "extension handshake is not a dict", allocator)
	}

	ext.messages = make(map[string]u8, allocator)
	if m_val, m_ok := bencode.dict_get(dict, "m"); m_ok {
		if m_dict, md_ok := bencode.as_dict(m_val); md_ok {
			for name, id_val in m_dict {
				if id, id_ok := bencode.as_i64(id_val); id_ok && id >= 0 && id <= 255 {
					ext.messages[strings.clone(name, allocator)] = u8(id)
				}
			}
		}
	}

	if client, ok := bencode.dict_string(dict, "v"); ok {
		ext.client = strings.clone(client, allocator)
	}
	ext.port, _ = bencode.dict_i64(dict, "p")
	ext.metadata_size, _ = bencode.dict_i64(dict, "metadata_size")
	ext.reqq, _ = bencode.dict_i64(dict, "reqq")
	if ip, ok := bencode.dict_string(dict, "yourip"); ok {
		ext.yourip = transmute([]byte)strings.clone(ip, allocator)
	}
	return ext, {}
}

extension_id :: proc(ext: Extended_Handshake, name: string) -> (id: u8, ok: bool) {
	id, ok = ext.messages[name]
	return
}
