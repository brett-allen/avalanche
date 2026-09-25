/*
	Multi-torrent engine: one OS thread per torrent, isolated state per handle.
	The Client (peer-id, listen port) is shared read-mostly across torrents.
*/
package session

import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "avalanche:metainfo"
import "avalanche:peer"
import "avalanche:storage"

Torrent_ID :: distinct u64

Torrent_State :: enum {
	Queued,
	Announcing,
	Downloading,
	Complete,
	Failed,
	Stopped,
}

Torrent_Status :: struct {
	id:           Torrent_ID,
	name:         string,
	infohash:     string,
	state:        Torrent_State,
	pieces_done:  int,
	pieces_total: int,
	bytes_done:   i64,
	bytes_total:  i64,
	peers_tried:  int,
	peers_live:   int,
	peers_failed: int,
	peers_active: int,
	error:        string,
	output:       string,
}

@(private)
Torrent :: struct {
	id:       Torrent_ID,
	engine:   ^Engine,
	mu:       sync.Mutex,
	magnet:   metainfo.Magnet,
	meta:     metainfo.Torrent,
	has_meta: bool,
	output:   string,
	status:   Torrent_Status,
	stop:     bool,
	thread:   ^thread.Thread,
}

Engine :: struct {
	client:    Client,
	mu:        sync.Mutex,
	torrents:  map[Torrent_ID]^Torrent,
	next_id:   Torrent_ID,
	allocator: mem.Allocator,
}

engine_make :: proc(port: u16 = DEFAULT_PORT, allocator := context.allocator) -> ^Engine {
	e := new(Engine, allocator)
	e.client = client_make(port)
	e.torrents = make(map[Torrent_ID]^Torrent, allocator)
	e.next_id = 1
	e.allocator = allocator
	return e
}

engine_destroy :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	engine_stop_all(e)

	ids: [dynamic]Torrent_ID
	sync.lock(&e.mu)
	for id in e.torrents {
		append(&ids, id)
	}
	sync.unlock(&e.mu)
	for id in ids {
		engine_remove(e, id)
	}
	delete(ids)

	delete(e.torrents)
	destroy(&e.client)
	free(e, e.allocator)
}

engine_add_magnet :: proc(
	e: ^Engine,
	uri: string,
	output: string = "downloads",
	allocator := context.allocator,
) -> (
	id: Torrent_ID,
	err: Error,
) {
	if e == nil {
		return 0, session_fail(.Invalid, "nil engine", allocator)
	}
	tor, aerr := add_magnet(&e.client, uri, allocator)
	if aerr.kind != .None {
		return 0, aerr
	}
	return engine_spawn(e, tor, output, allocator)
}

engine_add_torrent_file :: proc(
	e: ^Engine,
	path: string,
	output: string = "downloads",
	allocator := context.allocator,
) -> (
	id: Torrent_ID,
	err: Error,
) {
	if e == nil {
		return 0, session_fail(.Invalid, "nil engine", allocator)
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return 0, session_fail(.Invalid, "cannot read torrent file", allocator)
	}
	defer delete(data, allocator)

	meta, perr := metainfo.parse_torrent(data, allocator)
	if perr.kind != .None {
		return 0, session_fail(.Invalid, metainfo.error_string(perr), allocator)
	}

	tor: Torrent_Session
	tor.meta = meta
	tor.has_meta = true
	tor.magnet.info_hash = meta.info_hash
	if meta.info.name != "" {
		tor.magnet.display = strings.clone(meta.info.name, allocator)
	}
	if meta.announce != "" {
		append(&tor.magnet.trackers, strings.clone(meta.announce, allocator))
	} else if len(meta.announce_list) > 0 {
		for tier in meta.announce_list {
			for url in tier {
				append(&tor.magnet.trackers, strings.clone(url, allocator))
			}
		}
	}
	return engine_spawn(e, tor, output, allocator)
}

@(private)
engine_spawn :: proc(
	e: ^Engine,
	session_tor: Torrent_Session,
	output: string,
	allocator := context.allocator,
) -> (
	id: Torrent_ID,
	err: Error,
) {
	_ = allocator
	t := new(Torrent, e.allocator)
	t.engine = e
	t.magnet = session_tor.magnet
	t.meta = session_tor.meta
	t.has_meta = session_tor.has_meta
	t.output = strings.clone(output if output != "" else "downloads", e.allocator)

	sync.lock(&e.mu)
	id = e.next_id
	e.next_id += 1
	t.id = id
	t.status = Torrent_Status{
		id       = id,
		state    = .Queued,
		output   = strings.clone(t.output, e.allocator),
		name     = torrent_display_name(t),
		infohash = metainfo.info_hash_hex(t.magnet.info_hash, e.allocator),
	}
	if t.has_meta {
		t.status.pieces_total = metainfo.piece_count(t.meta.info)
		t.status.bytes_total = metainfo.total_length(t.meta.info)
		if t.meta.info.name != "" {
			delete(t.status.name, e.allocator)
			t.status.name = strings.clone(t.meta.info.name, e.allocator)
		}
	}
	e.torrents[id] = t
	sync.unlock(&e.mu)

	th := thread.create(torrent_worker)
	th.data = t
	t.thread = th
	thread.start(th)
	return id, {}
}

engine_status :: proc(e: ^Engine, id: Torrent_ID, allocator := context.allocator) -> (st: Torrent_Status, ok: bool) {
	if e == nil {
		return {}, false
	}
	sync.lock(&e.mu)
	t := e.torrents[id] or_else nil
	sync.unlock(&e.mu)
	if t == nil {
		return {}, false
	}
	sync.lock(&t.mu)
	st = clone_status(t.status, allocator)
	sync.unlock(&t.mu)
	return st, true
}

engine_list :: proc(e: ^Engine, allocator := context.allocator) -> []Torrent_Status {
	if e == nil {
		return nil
	}
	sync.lock(&e.mu)
	out := make([]Torrent_Status, len(e.torrents), allocator)
	i := 0
	for _, t in e.torrents {
		sync.lock(&t.mu)
		out[i] = clone_status(t.status, allocator)
		sync.unlock(&t.mu)
		i += 1
	}
	sync.unlock(&e.mu)
	return out
}

engine_stop :: proc(e: ^Engine, id: Torrent_ID) {
	if e == nil {
		return
	}
	sync.lock(&e.mu)
	t := e.torrents[id] or_else nil
	sync.unlock(&e.mu)
	if t == nil {
		return
	}
	sync.lock(&t.mu)
	t.stop = true
	if t.status.state == .Queued || t.status.state == .Announcing {
		t.status.state = .Stopped
	}
	sync.unlock(&t.mu)
}

engine_stop_all :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	sync.lock(&e.mu)
	for _, t in e.torrents {
		sync.lock(&t.mu)
		t.stop = true
		sync.unlock(&t.mu)
	}
	sync.unlock(&e.mu)
}

engine_wait :: proc(e: ^Engine, id: Torrent_ID) {
	if e == nil {
		return
	}
	sync.lock(&e.mu)
	t := e.torrents[id] or_else nil
	sync.unlock(&e.mu)
	if t == nil || t.thread == nil {
		return
	}
	thread.join(t.thread)
}

engine_wait_all :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	threads: [dynamic]^thread.Thread
	sync.lock(&e.mu)
	for _, t in e.torrents {
		if t.thread != nil {
			append(&threads, t.thread)
		}
	}
	sync.unlock(&e.mu)
	for th in threads {
		thread.join(th)
	}
	delete(threads)
}

engine_remove :: proc(e: ^Engine, id: Torrent_ID) {
	if e == nil {
		return
	}
	sync.lock(&e.mu)
	t, ok := e.torrents[id]
	if ok {
		delete_key(&e.torrents, id)
	}
	sync.unlock(&e.mu)
	if !ok || t == nil {
		return
	}
	if t.thread != nil {
		thread.join(t.thread)
		thread.destroy(t.thread)
		t.thread = nil
	}
	torrent_free(t)
}

status_destroy :: proc(st: ^Torrent_Status, allocator := context.allocator) {
	if st == nil {
		return
	}
	delete(st.name, allocator)
	delete(st.infohash, allocator)
	delete(st.error, allocator)
	delete(st.output, allocator)
	st^ = {}
}

torrent_state_string :: proc(s: Torrent_State) -> string {
	switch s {
	case .Queued:
		return "queued"
	case .Announcing:
		return "announcing"
	case .Downloading:
		return "downloading"
	case .Complete:
		return "complete"
	case .Failed:
		return "failed"
	case .Stopped:
		return "stopped"
	}
	return "unknown"
}

@(private)
clone_status :: proc(src: Torrent_Status, allocator := context.allocator) -> Torrent_Status {
	return Torrent_Status{
		id           = src.id,
		name         = strings.clone(src.name, allocator),
		infohash     = strings.clone(src.infohash, allocator),
		state        = src.state,
		pieces_done  = src.pieces_done,
		pieces_total = src.pieces_total,
		bytes_done   = src.bytes_done,
		bytes_total  = src.bytes_total,
		peers_tried  = src.peers_tried,
		peers_live   = src.peers_live,
		peers_failed = src.peers_failed,
		peers_active = src.peers_active,
		error        = strings.clone(src.error, allocator),
		output       = strings.clone(src.output, allocator),
	}
}

@(private)
torrent_display_name :: proc(t: ^Torrent) -> string {
	if t.has_meta && t.meta.info.name != "" {
		return strings.clone(t.meta.info.name, t.engine.allocator)
	}
	if t.magnet.display != "" {
		return strings.clone(t.magnet.display, t.engine.allocator)
	}
	hex := metainfo.info_hash_hex(t.magnet.info_hash, context.temp_allocator)
	return strings.clone(hex, t.engine.allocator)
}

@(private)
torrent_free :: proc(t: ^Torrent) {
	if t == nil {
		return
	}
	alloc := t.engine.allocator
	metainfo.magnet_destroy(&t.magnet, alloc)
	metainfo.destroy(&t.meta, alloc)
	delete(t.output, alloc)
	delete(t.status.name, alloc)
	delete(t.status.infohash, alloc)
	delete(t.status.error, alloc)
	delete(t.status.output, alloc)
	free(t, alloc)
}

@(private)
torrent_should_stop :: proc(t: ^Torrent) -> bool {
	sync.lock(&t.mu)
	defer sync.unlock(&t.mu)
	return t.stop
}

@(private)
torrent_set_state :: proc(t: ^Torrent, state: Torrent_State, err_msg: string = "") {
	sync.lock(&t.mu)
	t.status.state = state
	if err_msg != "" {
		delete(t.status.error, t.engine.allocator)
		t.status.error = strings.clone(err_msg, t.engine.allocator)
	}
	sync.unlock(&t.mu)
}

@(private)
torrent_progress_cb :: proc(p: peer.Progress, user: rawptr) {
	t := cast(^Torrent)user
	if t == nil {
		return
	}
	sync.lock(&t.mu)
	t.status.state = .Downloading
	t.status.pieces_done = p.pieces_done
	t.status.pieces_total = p.pieces_total
	t.status.bytes_done = p.bytes_done
	t.status.bytes_total = p.bytes_total
	t.status.peers_tried = p.peers_tried
	t.status.peers_live = p.peers_live
	t.status.peers_failed = p.peers_failed
	t.status.peers_active = len(p.active)
	sync.unlock(&t.mu)
}

@(private)
torrent_worker :: proc(th: ^thread.Thread) {
	t := cast(^Torrent)th.data
	e := t.engine
	alloc := e.allocator

	if torrent_should_stop(t) {
		torrent_set_state(t, .Stopped)
		return
	}

	torrent_set_state(t, .Announcing)

	peers, _ := collect_swarm(e.client, t.magnet, alloc)
	defer delete(peers)

	if torrent_should_stop(t) {
		torrent_set_state(t, .Stopped)
		return
	}

	if len(peers) == 0 {
		torrent_set_state(t, .Failed, "no peers from trackers")
		return
	}

	view := Torrent_Session{
		magnet   = t.magnet,
		meta     = t.meta,
		has_meta = t.has_meta,
	}
	if merr := ensure_metadata(e.client, &view, peers[:], alloc); merr.kind != .None {
		msg := error_string(merr)
		if merr.message != "" {
			delete(merr.message, alloc)
		}
		torrent_set_state(t, .Failed, msg)
		return
	}
	t.meta = view.meta
	t.has_meta = view.has_meta

	sync.lock(&t.mu)
	t.status.pieces_total = metainfo.piece_count(t.meta.info)
	t.status.bytes_total = metainfo.total_length(t.meta.info)
	if t.meta.info.name != "" {
		delete(t.status.name, alloc)
		t.status.name = strings.clone(t.meta.info.name, alloc)
	}
	sync.unlock(&t.mu)

	if torrent_should_stop(t) {
		torrent_set_state(t, .Stopped)
		return
	}

	store, serr := storage.open(t.output, t.meta.info, alloc)
	if serr.kind != .None {
		msg := storage.error_string(serr)
		if serr.message != "" {
			delete(serr.message, alloc)
		}
		torrent_set_state(t, .Failed, msg)
		return
	}
	defer storage.close(&store, alloc)

	torrent_set_state(t, .Downloading)

	local := peer.make_handshake(transmute([20]u8)t.meta.info_hash, e.client.peer_id)
	endpoints: [dynamic]net.Endpoint
	defer delete(endpoints)
	for p in peers {
		append(&endpoints, p.endpoint)
	}

	n, derr := peer.download_torrent(
		endpoints[:],
		local,
		t.meta.info,
		&store,
		e.client.listen_port,
		torrent_progress_cb,
		t,
		alloc,
	)

	sync.lock(&t.mu)
	t.status.pieces_done = n
	if derr.kind != .None {
		t.status.state = .Failed
		delete(t.status.error, alloc)
		t.status.error = strings.clone(peer.error_string(derr), alloc)
		if derr.message != "" {
			delete(derr.message, alloc)
		}
	} else if t.stop {
		t.status.state = .Stopped
	} else {
		t.status.state = .Complete
		t.status.pieces_done = t.status.pieces_total
		t.status.bytes_done = t.status.bytes_total
	}
	sync.unlock(&t.mu)
}
