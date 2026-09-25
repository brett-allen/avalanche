/*
	Piece-oriented file I/O. Positional reads/writes so nbio can issue them
	without sharing a file cursor.
*/
package storage

import "core:os"
import "core:path/filepath"
import "core:strings"
import "avalanche:metainfo"

Error_Kind :: enum {
	None,
	Not_Implemented,
	Open_Failed,
	IO,
	Invalid,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

File_Map :: struct {
	path:   string,
	offset: i64, // torrent-global start offset
	length: i64,
	handle: ^os.File,
}

Store :: struct {
	root:  string,
	info:  metainfo.Info,
	files: []File_Map,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Not_Implemented:
		return "storage: not implemented"
	case .Open_Failed:
		return err.message if err.message != "" else "storage: open failed"
	case .IO:
		return err.message if err.message != "" else "storage: i/o error"
	case .Invalid:
		return err.message if err.message != "" else "storage: invalid"
	}
	return "storage: unknown error"
}

@(private)
storage_fail :: proc(kind: Error_Kind, msg: string, allocator := context.allocator) -> Error {
	return Error{kind = kind, message = strings.clone(msg, allocator)}
}

open :: proc(root: string, info: metainfo.Info, allocator := context.allocator) -> (store: Store, err: Error) {
	if root == "" {
		return {}, storage_fail(.Invalid, "storage root is empty", allocator)
	}
	if metainfo.piece_count(info) == 0 || metainfo.total_length(info) <= 0 {
		return {}, storage_fail(.Invalid, "torrent info has no pieces", allocator)
	}

	store.root = strings.clone(root, allocator)
	store.info = info // borrowed; caller owns info strings

	if merr := os.make_directory_all(root); merr != nil {
		// ok if exists; make_directory_all should handle. If fail, continue and let open fail.
	}

	if metainfo.is_single_file(info) {
		name := info.name if info.name != "" else "download"
		path, _ := filepath.join({root, name}, allocator)
		store.files = make([]File_Map, 1, allocator)
		store.files[0] = File_Map{
			path   = path,
			offset = 0,
			length = info.length,
		}
	} else {
		base := info.name if info.name != "" else "download"
		store.files = make([]File_Map, len(info.files), allocator)
		off: i64
		for file, i in info.files {
			elems: [dynamic]string
			defer delete(elems)
			append(&elems, root)
			append(&elems, base)
			for part in file.path {
				append(&elems, part)
			}
			path, _ := filepath.join(elems[:], allocator)
			store.files[i] = File_Map{
				path   = path,
				offset = off,
				length = file.length,
			}
			off += file.length
		}
	}

	for &fm in store.files {
		dir := filepath.dir(fm.path)
		if dir != "" && dir != "." {
			_ = os.make_directory_all(dir)
		}
		f, ferr := os.open(fm.path, {.Read, .Write, .Create}, os.Permissions_Default_File)
		if ferr != nil {
			close(&store)
			return {}, storage_fail(.Open_Failed, "could not open torrent file", allocator)
		}
		fm.handle = f
		if fm.length > 0 {
			_, _ = os.seek(f, fm.length - 1, .Start)
			one: [1]byte
			_, _ = os.write(f, one[:])
		}
	}
	return store, {}
}

close :: proc(store: ^Store, allocator := context.allocator) {
	if store == nil {
		return
	}
	for fm in store.files {
		if fm.handle != nil {
			os.close(fm.handle)
		}
		delete(fm.path, allocator)
	}
	delete(store.files, allocator)
	delete(store.root, allocator)
	store^ = {}
}

read_piece :: proc(store: ^Store, index: int, buf: []byte) -> (n: int, err: Error) {
	if store == nil {
		return 0, Error{kind = .Invalid, message = "nil store"}
	}
	want := int(metainfo.piece_length_at(store.info, index))
	if want <= 0 || len(buf) < want {
		return 0, storage_fail(.Invalid, "piece buffer too small", context.allocator)
	}
	offset := metainfo.piece_offset(store.info, index)
	if werr := write_torrent_range(store, offset, buf[:want], .Read); werr.kind != .None {
		return 0, werr
	}
	return want, {}
}

write_piece :: proc(store: ^Store, index: int, data: []byte, allocator := context.allocator) -> Error {
	if store == nil {
		return storage_fail(.Invalid, "nil store", allocator)
	}
	if !metainfo.verify_piece(store.info, index, data) {
		return storage_fail(.Invalid, "piece hash mismatch", allocator)
	}
	offset := metainfo.piece_offset(store.info, index)
	return write_torrent_range(store, offset, data, .Write)
}

@(private)
Range_Op :: enum {
	Read,
	Write,
}

@(private)
write_torrent_range :: proc(store: ^Store, offset: i64, data: []byte, op: Range_Op) -> Error {
	remaining := data
	pos := offset
	for len(remaining) > 0 {
		fm, file_off, ok := map_offset(store, pos)
		if !ok || fm.handle == nil {
			return storage_fail(.IO, "torrent offset out of range", context.allocator)
		}
		avail := fm.length - file_off
		if avail <= 0 {
			return storage_fail(.IO, "torrent file mapping exhausted", context.allocator)
		}
		chunk := int(min(i64(len(remaining)), avail))
		switch op {
		case .Read:
			n, rerr := os.read_at(fm.handle, remaining[:chunk], file_off)
			if rerr != nil || n != chunk {
				return storage_fail(.IO, "piece read failed", context.allocator)
			}
		case .Write:
			n, werr := os.write_at(fm.handle, remaining[:chunk], file_off)
			if werr != nil || n != chunk {
				return storage_fail(.IO, "piece write failed", context.allocator)
			}
		}
		remaining = remaining[chunk:]
		pos += i64(chunk)
	}
	return {}
}

@(private)
map_offset :: proc(store: ^Store, offset: i64) -> (fm: ^File_Map, file_off: i64, ok: bool) {
	for &f in store.files {
		if offset >= f.offset && offset < f.offset + f.length {
			return &f, offset - f.offset, true
		}
	}
	return nil, 0, false
}
