package metainfo

import "core:crypto/hash"
import "core:strings"

piece_length_at :: proc(info: Info, index: int) -> i64 {
	count := piece_count(info)
	if index < 0 || index >= count || info.piece_length <= 0 {
		return 0
	}
	total := total_length(info)
	offset := i64(index) * info.piece_length
	remain := total - offset
	if remain < info.piece_length {
		return remain
	}
	return info.piece_length
}

piece_offset :: proc(info: Info, index: int) -> i64 {
	if index < 0 {
		return 0
	}
	return i64(index) * info.piece_length
}

piece_hash :: proc(info: Info, index: int) -> (digest: [20]u8, ok: bool) {
	start := index * 20
	if start < 0 || start + 20 > len(info.pieces) {
		return {}, false
	}
	copy(digest[:], info.pieces[start:start + 20])
	return digest, true
}

verify_piece :: proc(info: Info, index: int, data: []byte) -> bool {
	want, ok := piece_hash(info, index)
	if !ok {
		return false
	}
	if i64(len(data)) != piece_length_at(info, index) {
		return false
	}
	got: [20]u8
	hash.hash(.Insecure_SHA1, data, got[:])
	return got == want
}

File_Progress :: struct {
	name:  string,
	done:  i64,
	total: i64,
}

// file_progress reports how many bytes of each torrent file are covered by
// completed pieces. `have` is true for each finished piece index.
file_progress :: proc(
	info: Info,
	have: []bool,
	allocator := context.allocator,
) -> []File_Progress {
	if is_single_file(info) {
		name := info.name if info.name != "" else "download"
		done := bytes_covered(info, 0, info.length, have)
		out := make([]File_Progress, 1, allocator)
		out[0] = File_Progress{name = strings.clone(name, allocator), done = done, total = info.length}
		return out
	}

	out := make([]File_Progress, len(info.files), allocator)
	off: i64
	base := info.name if info.name != "" else ""
	for file, i in info.files {
		name := join_file_path(base, file.path, allocator)
		done := bytes_covered(info, off, file.length, have)
		out[i] = File_Progress{name = name, done = done, total = file.length}
		off += file.length
	}
	return out
}

file_progress_destroy :: proc(files: []File_Progress, allocator := context.allocator) {
	for f in files {
		delete(f.name, allocator)
	}
	delete(files, allocator)
}

@(private)
join_file_path :: proc(base: string, parts: []string, allocator := context.allocator) -> string {
	if len(parts) == 0 {
		return strings.clone(base if base != "" else "file", allocator)
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	defer strings.builder_destroy(&b)
	if base != "" {
		strings.write_string(&b, base)
		strings.write_byte(&b, '/')
	}
	for part, i in parts {
		if i > 0 {
			strings.write_byte(&b, '/')
		}
		strings.write_string(&b, part)
	}
	return strings.clone(strings.to_string(b), allocator)
}

@(private)
bytes_covered :: proc(info: Info, file_off, file_len: i64, have: []bool) -> i64 {
	if file_len <= 0 {
		return 0
	}
	file_end := file_off + file_len
	done: i64
	for index in 0 ..< len(have) {
		if !have[index] {
			continue
		}
		p_off := piece_offset(info, index)
		p_len := piece_length_at(info, index)
		p_end := p_off + p_len
		start := max(p_off, file_off)
		end := min(p_end, file_end)
		if end > start {
			done += end - start
		}
	}
	return done
}
