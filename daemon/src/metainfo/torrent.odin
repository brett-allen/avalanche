/*
	Metainfo for v1 torrents (BEP 3) and magnet links (BEP 9).
	v2 / hybrid (BEP 52) comes later.
*/
package metainfo

import "core:crypto/hash"
import "core:strings"
import "avalanche:bencode"

Info_Hash :: distinct [20]u8

File :: struct {
	path:   []string,
	length: i64,
}

Info :: struct {
	name:         string,
	piece_length: i64,
	pieces:       []byte,
	length:       i64,
	files:        []File,
	private:      bool,
}

Torrent :: struct {
	announce:      string,
	announce_list: [][]string,
	comment:       string,
	created_by:    string,
	creation_date: i64,
	info:          Info,
	info_hash:     Info_Hash,
	info_raw:      []byte, // exact bencoded info dict (for resume / re-hash)
}

parse_torrent :: proc(data: []byte, allocator := context.allocator) -> (torrent: Torrent, err: Error) {
	if len(data) == 0 {
		return {}, Error{kind = .Empty_Input}
	}

	root, perr := bencode.parse(data, allocator)
	if perr.kind != .None {
		return {}, Error{kind = .Invalid, message = bencode.error_string(perr)}
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, Error{kind = .Invalid, message = "torrent is not a dict"}
	}

	info_val, info_ok := bencode.dict_get(dict, "info")
	if !info_ok {
		return {}, Error{kind = .Invalid, message = "torrent missing info dict"}
	}
	info_dict, info_dict_ok := bencode.as_dict(info_val)
	if !info_dict_ok {
		return {}, Error{kind = .Invalid, message = "torrent info is not a dict"}
	}

	raw_info, raw_err := bencode.raw_top_value(data, "info")
	if raw_err.kind != .None || len(raw_info) == 0 {
		return {}, Error{kind = .Invalid, message = "torrent missing info bytes"}
	}
	hash.hash(.Insecure_SHA1, raw_info, torrent.info_hash[:])
	torrent.info_raw = make([]byte, len(raw_info), allocator)
	copy(torrent.info_raw, raw_info)

	torrent.announce, _ = clone_dict_string(dict, "announce", allocator)
	torrent.comment, _ = clone_dict_string(dict, "comment", allocator)
	torrent.created_by, _ = clone_dict_string(dict, "created by", allocator)
	torrent.creation_date, _ = bencode.dict_i64(dict, "creation date")
	torrent.announce_list = clone_announce_list(dict, allocator)

	info_err: Error
	torrent.info, info_err = decode_info(info_dict, allocator)
	if info_err.kind != .None {
		destroy(&torrent, allocator)
		return {}, info_err
	}
	return torrent, {}
}

parse_info :: proc(data: []byte, allocator := context.allocator) -> (info: Info, info_hash: Info_Hash, err: Error) {
	if len(data) == 0 {
		return {}, {}, Error{kind = .Empty_Input}
	}
	hash.hash(.Insecure_SHA1, data, info_hash[:])

	root, perr := bencode.parse(data, allocator)
	if perr.kind != .None {
		return {}, info_hash, Error{kind = .Invalid, message = bencode.error_string(perr)}
	}
	defer bencode.destroy(&root, allocator)

	dict, dict_ok := bencode.as_dict(root)
	if !dict_ok {
		return {}, info_hash, Error{kind = .Invalid, message = "info is not a dict"}
	}
	info, err = decode_info(dict, allocator)
	if err.kind != .None {
		info_destroy(&info, allocator)
		return {}, info_hash, err
	}
	return info, info_hash, {}
}

info_destroy :: proc(info: ^Info, allocator := context.allocator) {
	if info == nil {
		return
	}
	delete(info.name, allocator)
	delete(info.pieces, allocator)
	for file in info.files {
		for part in file.path {
			delete(part, allocator)
		}
		delete(file.path, allocator)
	}
	delete(info.files, allocator)
	info^ = {}
}

destroy :: proc(torrent: ^Torrent, allocator := context.allocator) {
	if torrent == nil {
		return
	}
	delete(torrent.announce, allocator)
	for tier in torrent.announce_list {
		for url in tier {
			delete(url, allocator)
		}
		delete(tier, allocator)
	}
	delete(torrent.announce_list, allocator)
	delete(torrent.comment, allocator)
	delete(torrent.created_by, allocator)
	delete(torrent.info_raw, allocator)
	info_destroy(&torrent.info, allocator)
	torrent^ = {}
}

is_single_file :: proc(info: Info) -> bool {
	return len(info.files) == 0 && info.length > 0
}

total_length :: proc(info: Info) -> i64 {
	if is_single_file(info) {
		return info.length
	}
	n: i64
	for file in info.files {
		n += file.length
	}
	return n
}

piece_count :: proc(info: Info) -> int {
	return len(info.pieces) / 20
}

@(private)
decode_info :: proc(dict: bencode.Dict, allocator := context.allocator) -> (info: Info, err: Error) {
	info.name, _ = clone_dict_string(dict, "name", allocator)
	if info.name == "" {
		info.name, _ = clone_dict_string(dict, "name.utf-8", allocator)
	}
	info.piece_length, _ = bencode.dict_i64(dict, "piece length")
	if pieces, ok := bencode.dict_string(dict, "pieces"); ok {
		info.pieces = transmute([]byte)strings.clone(pieces, allocator)
	}
	info.length, _ = bencode.dict_i64(dict, "length")
	if private, ok := bencode.dict_i64(dict, "private"); ok {
		info.private = private != 0
	}

	if files_val, ok := bencode.dict_get(dict, "files"); ok {
		files_list, list_ok := bencode.as_list(files_val)
		if !list_ok {
			err = Error{kind = .Invalid, message = "info.files is not a list"}
			return info, err
		}
		info.files = make([]File, len(files_list), allocator)
		for file_val, i in files_list {
			file_dict, file_ok := bencode.as_dict(file_val)
			if !file_ok {
				err = Error{kind = .Invalid, message = "info.files entry is not a dict"}
				return info, err
			}
			info.files[i].length, _ = bencode.dict_i64(file_dict, "length")
			if path_val, path_ok := bencode.dict_get(file_dict, "path"); path_ok {
				info.files[i].path = clone_string_list(path_val, allocator)
			}
		}
	}

	if info.piece_length <= 0 || len(info.pieces) == 0 || len(info.pieces) % 20 != 0 {
		err = Error{kind = .Invalid, message = "torrent info is missing pieces"}
		return info, err
	}
	if info.length <= 0 && len(info.files) == 0 {
		err = Error{kind = .Invalid, message = "torrent has no file length"}
		return info, err
	}
	return info, {}
}

@(private)
clone_dict_string :: proc(dict: bencode.Dict, key: string, allocator := context.allocator) -> (s: string, ok: bool) {
	raw := bencode.dict_string(dict, key) or_return
	return strings.clone(raw, allocator), true
}

@(private)
clone_announce_list :: proc(dict: bencode.Dict, allocator := context.allocator) -> [][]string {
	val, ok := bencode.dict_get(dict, "announce-list")
	if !ok {
		return nil
	}
	tiers, tiers_ok := bencode.as_list(val)
	if !tiers_ok {
		return nil
	}
	out := make([][]string, len(tiers), allocator)
	for tier_val, i in tiers {
		out[i] = clone_string_list(tier_val, allocator)
	}
	return out
}

@(private)
clone_string_list :: proc(value: bencode.Value, allocator := context.allocator) -> []string {
	list, ok := bencode.as_list(value)
	if !ok {
		return nil
	}
	out := make([]string, len(list), allocator)
	for item, i in list {
		if s, s_ok := bencode.as_string(item); s_ok {
			out[i] = strings.clone(s, allocator)
		}
	}
	return out
}
