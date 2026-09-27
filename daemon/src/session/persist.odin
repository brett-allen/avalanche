/*
	On-disk session state so torrents survive daemon restart without
	re-fetching metadata or re-downloading completed pieces.

	Layout under each download root:
	  {output}/.avalanche/session.json
	  {output}/.avalanche/{infohash40}/meta.json
	  {output}/.avalanche/{infohash40}/info.bencode
	  {output}/.avalanche/{infohash40}/bitfield.bin
*/
package session

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "avalanche:metainfo"

PERSIST_VERSION :: 1
PERSIST_DIR_NAME :: ".avalanche"

Session_Index_JSON :: struct {
	version:  int                   `json:"version"`,
	torrents: []Session_Entry_JSON  `json:"torrents"`,
}

Session_Entry_JSON :: struct {
	infohash: string `json:"infohash"`,
	output:   string `json:"output"`,
}

Torrent_Meta_JSON :: struct {
	version:      int    `json:"version"`,
	infohash:     string `json:"infohash"`,
	name:         string `json:"name"`,
	output:       string `json:"output"`,
	magnet:       string `json:"magnet"`,
	state:        string `json:"state"`,
	pieces_total: int    `json:"pieces_total"`,
	pieces_done:  int    `json:"pieces_done"`,
}

persist_root :: proc(output: string, allocator := context.allocator) -> string {
	root := output if output != "" else "downloads"
	path, _ := filepath.join({root, PERSIST_DIR_NAME}, allocator)
	return path
}

persist_torrent_dir :: proc(output, infohash_hex: string, allocator := context.allocator) -> string {
	base := persist_root(output, context.temp_allocator)
	path, _ := filepath.join({base, infohash_hex}, allocator)
	return path
}

@(private)
persist_ensure_dir :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	if os.exists(path) {
		return true
	}
	return os.make_directory_all(path) == nil
}

@(private)
persist_write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}

// persist_save_torrent writes metadata + bitfield for one torrent (best-effort).
persist_save_torrent :: proc(t: ^Torrent) {
	if t == nil || !t.has_meta || len(t.meta.info_raw) == 0 {
		return
	}
	hex := t.status.infohash
	if hex == "" {
		hex = metainfo.info_hash_hex(t.magnet.info_hash, context.temp_allocator)
	}
	dir := persist_torrent_dir(t.output, hex, context.temp_allocator)
	if !persist_ensure_dir(dir) {
		log.warnf("persist: cannot create %s", dir)
		return
	}

	info_path, _ := filepath.join({dir, "info.bencode"}, context.temp_allocator)
	if !persist_write_file(info_path, t.meta.info_raw) {
		log.warnf("persist: failed writing %s", info_path)
		return
	}

	sync.lock(&t.mu)
	have := t.have_bits
	pieces_done := t.status.pieces_done
	pieces_total := t.status.pieces_total
	state := torrent_state_string(t.status.state)
	name := strings.clone(t.status.name, context.temp_allocator)
	magnet := strings.clone(t.magnet_uri, context.temp_allocator)
	output := strings.clone(t.output, context.temp_allocator)
	sync.unlock(&t.mu)

	if len(have) > 0 {
		bf_path, _ := filepath.join({dir, "bitfield.bin"}, context.temp_allocator)
		if !persist_write_file(bf_path, have) {
			log.warnf("persist: failed writing %s", bf_path)
		}
	}

	meta := Torrent_Meta_JSON{
		version      = PERSIST_VERSION,
		infohash     = hex,
		name         = name,
		output       = output,
		magnet       = magnet,
		state        = state,
		pieces_total = pieces_total,
		pieces_done  = pieces_done,
	}
	data, jerr := json.marshal(meta, allocator = context.temp_allocator)
	if jerr != nil {
		log.warnf("persist: marshal meta: %v", jerr)
		return
	}
	meta_path, _ := filepath.join({dir, "meta.json"}, context.temp_allocator)
	if !persist_write_file(meta_path, data) {
		log.warnf("persist: failed writing %s", meta_path)
	}
}

// persist_save_index rewrites session.json under download_dir from live engine state.
persist_save_index :: proc(e: ^Engine, download_dir: string) {
	if e == nil {
		return
	}
	root := persist_root(download_dir, context.temp_allocator)
	if !persist_ensure_dir(root) {
		log.warnf("persist: cannot create %s", root)
		return
	}

	entries: [dynamic]Session_Entry_JSON
	entries.allocator = context.temp_allocator

	sync.lock(&e.mu)
	for _, t in e.torrents {
		sync.lock(&t.mu)
		if t.has_meta && t.status.infohash != "" {
			append(&entries, Session_Entry_JSON{
				infohash = strings.clone(t.status.infohash, context.temp_allocator),
				output   = strings.clone(t.output, context.temp_allocator),
			})
		}
		sync.unlock(&t.mu)
	}
	sync.unlock(&e.mu)

	idx := Session_Index_JSON{
		version  = PERSIST_VERSION,
		torrents = entries[:],
	}
	data, jerr := json.marshal(idx, allocator = context.temp_allocator)
	if jerr != nil {
		log.warnf("persist: marshal index: %v", jerr)
		return
	}
	path, _ := filepath.join({root, "session.json"}, context.temp_allocator)
	if !persist_write_file(path, data) {
		log.warnf("persist: failed writing %s", path)
		return
	}
	log.debugf("persist: wrote index %s (%d torrents)", path, len(entries))
}

persist_remove_torrent :: proc(output, infohash_hex: string) {
	if infohash_hex == "" {
		return
	}
	dir := persist_torrent_dir(output, infohash_hex, context.temp_allocator)
	info_path, _ := filepath.join({dir, "info.bencode"}, context.temp_allocator)
	meta_path, _ := filepath.join({dir, "meta.json"}, context.temp_allocator)
	bf_path, _ := filepath.join({dir, "bitfield.bin"}, context.temp_allocator)
	_ = os.remove(info_path)
	_ = os.remove(meta_path)
	_ = os.remove(bf_path)
	_ = os.remove(dir)
	log.infof("persist: removed %s", dir)
}

// persist_load_torrent reads one torrent's resume state from disk.
persist_load_torrent :: proc(
	output, infohash_hex: string,
	allocator := context.allocator,
) -> (
	session_tor: Torrent_Session,
	magnet_uri: string,
	have_bits: []byte,
	ok: bool,
) {
	dir := persist_torrent_dir(output, infohash_hex, context.temp_allocator)
	info_path, _ := filepath.join({dir, "info.bencode"}, context.temp_allocator)
	meta_path, _ := filepath.join({dir, "meta.json"}, context.temp_allocator)
	bf_path, _ := filepath.join({dir, "bitfield.bin"}, context.temp_allocator)

	raw, rerr := os.read_entire_file(info_path, allocator)
	if rerr != nil || len(raw) == 0 {
		return {}, "", nil, false
	}

	info, ih, ierr := metainfo.parse_info(raw, allocator)
	if ierr.kind != .None {
		delete(raw, allocator)
		return {}, "", nil, false
	}
	got_hex := metainfo.info_hash_hex(ih, context.temp_allocator)
	if !strings.equal_fold(got_hex, infohash_hex) {
		metainfo.info_destroy(&info, allocator)
		delete(raw, allocator)
		log.warnf("persist: infohash mismatch in %s", info_path)
		return {}, "", nil, false
	}

	session_tor.meta.info = info
	session_tor.meta.info_hash = ih
	session_tor.meta.info_raw = raw
	session_tor.has_meta = true
	session_tor.magnet.info_hash = ih

	meta_data, merr := os.read_entire_file(meta_path, context.temp_allocator)
	magnet := ""
	name := ""
	if merr == nil {
		meta: Torrent_Meta_JSON
		if jerr := json.unmarshal(meta_data, &meta, allocator = context.temp_allocator); jerr == nil {
			magnet = meta.magnet
			name = meta.name
		}
	}

	if magnet != "" {
		m, perr := metainfo.parse_magnet(magnet, allocator)
		if perr.kind == .None {
			session_tor.magnet = m
			magnet_uri = strings.clone(magnet, allocator)
		} else {
			magnet_uri = metainfo.magnet_format(session_tor.magnet, allocator)
			if name != "" {
				session_tor.magnet.display = strings.clone(name, allocator)
			}
		}
	} else {
		if name != "" {
			session_tor.magnet.display = strings.clone(name, allocator)
		}
		magnet_uri = metainfo.magnet_format(session_tor.magnet, allocator)
	}

	if bf_data, berr := os.read_entire_file(bf_path, allocator); berr == nil {
		have_bits = bf_data
	}

	ok = true
	return
}

// persist_load_index reads session.json; missing file is not an error.
persist_load_index :: proc(
	download_dir: string,
	allocator := context.allocator,
) -> (
	entries: []Session_Entry_JSON,
	ok: bool,
) {
	root := persist_root(download_dir, context.temp_allocator)
	path, _ := filepath.join({root, "session.json"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	idx: Session_Index_JSON
	if jerr := json.unmarshal(data, &idx, allocator = allocator); jerr != nil {
		log.warnf("persist: invalid session index %s: %v", path, jerr)
		return nil, false
	}
	return idx.torrents, true
}

persist_index_destroy :: proc(entries: []Session_Entry_JSON, allocator := context.allocator) {
	for e in entries {
		delete(e.infohash, allocator)
		delete(e.output, allocator)
	}
	delete(entries, allocator)
}
