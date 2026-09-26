/*
	Multi-torrent engine: one OS thread per torrent, isolated state per handle.
	The Client (peer-id, listen port) is shared read-mostly across torrents.
*/
package session

import "core:log"
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
	down_rate:    i64, // bytes/sec
	up_rate:      i64, // bytes/sec (leech-only for now)
	peers_tried:  int,
	peers_live:   int,
	peers_failed: int,
	peers_active: int,
	error:        string,
	output:       string,
}

Peer_Detail :: struct {
	endpoint:  string,
	client:    string,
	down_rate: i64,
}

Torrent_Detail :: struct {
	id:        Torrent_ID,
	files:     []metainfo.File_Progress,
	peers:     []Peer_Detail,
	down_rate: i64,
	up_rate:   i64,
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
	// Detail snapshot — refreshed from peer progress; served only on demand.
	detail_files: []metainfo.File_Progress,
	detail_peers: []Peer_Detail,
	// Live peer sockets so Stop can unblock reads promptly.
	sock_mu: sync.Mutex,
	socks:   map[int]net.TCP_Socket,
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
	th.init_context = context
	t.thread = th
	thread.start(th)
	log.infof("torrent %d queued infohash=%s", int(id), t.status.infohash)
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

// engine_details returns file + per-peer stats. Call only when a UI needs them.
engine_details :: proc(
	e: ^Engine,
	id: Torrent_ID,
	allocator := context.allocator,
) -> (
	detail: Torrent_Detail,
	ok: bool,
) {
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
	defer sync.unlock(&t.mu)
	detail.id = t.id
	detail.down_rate = t.status.down_rate
	detail.up_rate = t.status.up_rate
	detail.files = clone_files(t.detail_files, allocator)
	detail.peers = clone_peers(t.detail_peers, allocator)
	return detail, true
}

detail_destroy :: proc(d: ^Torrent_Detail, allocator := context.allocator) {
	if d == nil {
		return
	}
	metainfo.file_progress_destroy(d.files, allocator)
	for p in d.peers {
		delete(p.endpoint, allocator)
		delete(p.client, allocator)
	}
	delete(d.peers, allocator)
	d^ = {}
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
	if t.status.state != .Complete && t.status.state != .Failed {
		t.status.state = .Stopped
	}
	t.status.down_rate = 0
	t.status.up_rate = 0
	t.status.peers_active = 0
	sync.unlock(&t.mu)
	torrent_interrupt_peers(t)
}

engine_stop_all :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	sync.lock(&e.mu)
	for _, t in e.torrents {
		sync.lock(&t.mu)
		t.stop = true
		if t.status.state != .Complete && t.status.state != .Failed {
			t.status.state = .Stopped
		}
		t.status.down_rate = 0
		t.status.up_rate = 0
		sync.unlock(&t.mu)
		torrent_interrupt_peers(t)
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
		down_rate    = src.down_rate,
		up_rate      = src.up_rate,
		peers_tried  = src.peers_tried,
		peers_live   = src.peers_live,
		peers_failed = src.peers_failed,
		peers_active = src.peers_active,
		error        = strings.clone(src.error, allocator),
		output       = strings.clone(src.output, allocator),
	}
}

@(private)
clone_files :: proc(src: []metainfo.File_Progress, allocator := context.allocator) -> []metainfo.File_Progress {
	if len(src) == 0 {
		return nil
	}
	out := make([]metainfo.File_Progress, len(src), allocator)
	for f, i in src {
		out[i] = metainfo.File_Progress{
			name  = strings.clone(f.name, allocator),
			done  = f.done,
			total = f.total,
		}
	}
	return out
}

@(private)
clone_peers :: proc(src: []Peer_Detail, allocator := context.allocator) -> []Peer_Detail {
	if len(src) == 0 {
		return nil
	}
	out := make([]Peer_Detail, len(src), allocator)
	for p, i in src {
		out[i] = Peer_Detail{
			endpoint  = strings.clone(p.endpoint, allocator),
			client    = strings.clone(p.client, allocator),
			down_rate = p.down_rate,
		}
	}
	return out
}

@(private)
torrent_clear_detail :: proc(t: ^Torrent) {
	metainfo.file_progress_destroy(t.detail_files, t.engine.allocator)
	t.detail_files = nil
	for p in t.detail_peers {
		delete(p.endpoint, t.engine.allocator)
		delete(p.client, t.engine.allocator)
	}
	delete(t.detail_peers, t.engine.allocator)
	t.detail_peers = nil
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
	torrent_clear_detail(t)
	delete(t.socks)
	free(t, alloc)
}

@(private)
torrent_interrupt_peers :: proc(t: ^Torrent) {
	if t == nil {
		return
	}
	sync.lock(&t.sock_mu)
	for slot, sock in t.socks {
		if sock != 0 {
			_ = net.shutdown(sock, .Both)
			t.socks[slot] = 0
		}
	}
	clear(&t.socks)
	sync.unlock(&t.sock_mu)
}

@(private)
torrent_stop_check :: proc(user: rawptr) -> bool {
	t := cast(^Torrent)user
	return torrent_should_stop(t)
}

@(private)
torrent_on_sock :: proc(user: rawptr, slot: int, sock: net.TCP_Socket) {
	t := cast(^Torrent)user
	if t == nil || slot < 0 {
		return
	}
	sync.lock(&t.sock_mu)
	if t.socks == nil {
		t.socks = make(map[int]net.TCP_Socket, t.engine.allocator)
	}
	if sock == 0 {
		delete_key(&t.socks, slot)
	} else {
		t.socks[slot] = sock
	}
	sync.unlock(&t.sock_mu)
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
	stopping := t.stop
	if stopping {
		t.status.state = .Stopped
		t.status.down_rate = 0
		t.status.up_rate = 0
	} else {
		t.status.state = .Downloading
		t.status.down_rate = p.down_rate
		t.status.up_rate = 0
	}
	t.status.pieces_done = p.pieces_done
	t.status.pieces_total = p.pieces_total
	t.status.bytes_done = p.bytes_done
	t.status.bytes_total = p.bytes_total
	t.status.peers_tried = p.peers_tried
	t.status.peers_live = p.peers_live
	t.status.peers_failed = p.peers_failed
	t.status.peers_active = 0 if stopping else len(p.active)

	// Refresh on-demand detail cache (not exposed by list/get unless requested).
	alloc := t.engine.allocator
	torrent_clear_detail(t)
	if len(p.files) > 0 {
		t.detail_files = clone_files(p.files, alloc)
	}
	if !stopping && len(p.active) > 0 {
		peers := make([]Peer_Detail, len(p.active), alloc)
		for a, i in p.active {
			peers[i] = Peer_Detail{
				endpoint  = strings.clone(a.endpoint, alloc),
				client    = strings.clone(a.client, alloc),
				down_rate = a.down_rate,
			}
		}
		t.detail_peers = peers
	}
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
	log.infof("torrent %d announcing…", int(t.id))

	listener, lerr := peer.listen_peers(e.client.listen_port, alloc)
	if lerr.kind != .None {
		log.debugf("torrent %d: listen failed: %s", int(t.id), lerr.message)
		if lerr.message != "" {
			delete(lerr.message, alloc)
		}
		listener = 0
	} else {
		log.infof("torrent %d: listening for peers on tcp/%d", int(t.id), int(e.client.listen_port))
	}
	defer if listener != 0 {
		net.close(listener)
	}

	peers, _ := collect_swarm(e.client, t.magnet, alloc)
	defer delete(peers)

	if torrent_should_stop(t) {
		torrent_set_state(t, .Stopped)
		return
	}

	if len(peers) == 0 && listener == 0 {
		log.errorf("torrent %d: no peers from trackers or DHT", int(t.id))
		torrent_set_state(t, .Failed, "no peers from trackers or DHT")
		return
	}

	view := Torrent_Session{
		magnet   = t.magnet,
		meta     = t.meta,
		has_meta = t.has_meta,
	}
	if merr := ensure_metadata(e.client, &view, peers[:], alloc, listener); merr.kind != .None {
		// Clone before free — error_string may alias merr.message.
		msg := strings.clone(error_string(merr), alloc)
		if merr.message != "" {
			delete(merr.message, alloc)
		}
		log.errorf("torrent %d: %s", int(t.id), msg)
		torrent_set_state(t, .Failed, msg)
		delete(msg, alloc)
		return
	}
	t.meta = view.meta
	t.has_meta = view.has_meta
	log.infof("torrent %d: metadata ok name=%q pieces=%d",
		int(t.id), t.meta.info.name, metainfo.piece_count(t.meta.info))

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
	log.infof("torrent %d: downloading %q (%d pieces)",
		int(t.id), t.meta.info.name, metainfo.piece_count(t.meta.info))

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
		torrent_stop_check,
		torrent_on_sock,
		alloc,
	)

	sync.lock(&t.mu)
	t.status.pieces_done = n
	t.status.down_rate = 0
	t.status.up_rate = 0
	t.status.peers_active = 0
	if t.stop {
		t.status.state = .Stopped
		log.infof("torrent %d: stopped (%d pieces)", int(t.id), n)
		if derr.kind != .None && derr.message != "" {
			delete(derr.message, alloc)
		}
	} else if derr.kind != .None {
		t.status.state = .Failed
		delete(t.status.error, alloc)
		t.status.error = strings.clone(peer.error_string(derr), alloc)
		log.errorf("torrent %d: download failed: %s", int(t.id), t.status.error)
		if derr.message != "" {
			delete(derr.message, alloc)
		}
	} else {
		t.status.state = .Complete
		t.status.pieces_done = t.status.pieces_total
		t.status.bytes_done = t.status.bytes_total
		log.infof("torrent %d: complete (%d pieces)", int(t.id), t.status.pieces_total)
	}
	sync.unlock(&t.mu)
}
