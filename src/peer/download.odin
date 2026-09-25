/*
	BEP 3 piece download over peer connections (multi-peer).
*/
package peer

import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "avalanche:metainfo"
import "avalanche:storage"

DOWNLOAD_TIMEOUT     :: 30 * time.Second
MAX_PEER_TRIES       :: 64
MAX_CONCURRENT_PEERS :: 8
MAX_ACTIVE_DISPLAY   :: 8

Progress_Event :: enum {
	Peer_Try,
	Peer_Live,
	Peer_Fail,
	Piece,
}

Active_Peer :: struct {
	endpoint: string,
	client:   string,
}

Progress :: struct {
	event:        Progress_Event,
	pieces_done:  int,
	pieces_total: int,
	bytes_done:   i64,
	bytes_total:  i64,
	peer:         string,
	peer_client:  string,
	peers_tried:  int,
	peers_live:   int,
	peers_failed: int,
	active:       []Active_Peer,
	files:        []metainfo.File_Progress,
}

Progress_Proc :: #type proc(p: Progress, user: rawptr)

Peer_Session :: struct {
	sock:          net.TCP_Socket,
	remote:        Handshake,
	extended:      Extended_Handshake,
	got_extended:  bool,
	bitfield:      Bitfield,
	peer_choking:  bool,
	am_interested: bool,
}

@(private)
Swarm :: struct {
	mu:           sync.Mutex,
	info:         metainfo.Info,
	store:        ^storage.Store,
	local:        Handshake,
	listen_port:  u16,
	have:         Bitfield,
	claimed:      Bitfield,
	endpoints:    []net.Endpoint,
	next_ep:      int,
	peers_tried:  int,
	peers_live:   int,
	peers_failed: int,
	pieces_got:   int,
	on_progress:  Progress_Proc,
	progress_user: rawptr,
	active:       [MAX_CONCURRENT_PEERS]Active_Peer,
	active_on:    [MAX_CONCURRENT_PEERS]bool,
	allocator:    mem.Allocator,
}

peer_session_destroy :: proc(ps: ^Peer_Session, allocator := context.allocator) {
	if ps == nil {
		return
	}
	if ps.sock != 0 {
		net.close(ps.sock)
		ps.sock = 0
	}
	extended_destroy(&ps.extended, allocator)
	bitfield_destroy(&ps.bitfield, allocator)
	ps^ = {}
}

connect_session :: proc(
	endpoint: net.Endpoint,
	local: Handshake,
	piece_count: int,
	listen_port: u16 = 0,
	want_metadata: bool = false,
	want_hash: [20]u8 = {},
	timeout: time.Duration = HANDSHAKE_TIMEOUT,
	allocator := context.allocator,
) -> (
	ps: Peer_Session,
	metadata: []byte,
	err: Error,
) {
	sock, cerr := dial_tcp_timeout(endpoint, timeout, allocator)
	if cerr.kind != .None {
		return {}, nil, cerr
	}
	ps.sock = sock
	ps.peer_choking = true

	out, eerr := encode_handshake(local, allocator)
	if eerr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, eerr
	}
	defer delete(out, allocator)

	if werr := write_all(sock, out, allocator); werr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, werr
	}

	in_buf: [HANDSHAKE_SIZE]byte
	if rerr := read_all(sock, in_buf[:], allocator); rerr.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, rerr
	}

	ps.remote, err = decode_handshake(in_buf[:], allocator)
	if err.kind != .None {
		peer_session_destroy(&ps, allocator)
		return {}, nil, err
	}
	if ps.remote.info_hash != local.info_hash {
		peer_session_destroy(&ps, allocator)
		return {}, nil, peer_fail(.Protocol, "peer infohash mismatch", allocator)
	}

	ps.bitfield = bitfield_make(piece_count, allocator)
	_ = net.set_option(sock, .Receive_Timeout, DOWNLOAD_TIMEOUT)
	_ = net.set_option(sock, .Send_Timeout, DOWNLOAD_TIMEOUT)

	if has_extension(local) && has_extension(ps.remote) {
		if xerr := send_extended_handshake(sock, listen_port, allocator); xerr.kind != .None {
			peer_session_destroy(&ps, allocator)
			return {}, nil, xerr
		}
	}

	for i in 0 ..< MAX_SKIP_MESSAGES {
		if ps.got_extended && bitfield_any(ps.bitfield) {
			break
		}
		if !has_extension(ps.remote) && i > 2 {
			break
		}
		msg, merr := read_message(sock, allocator)
		if merr.kind != .None {
			if merr.kind == .Timeout {
				if merr.message != "" {
					delete(merr.message, allocator)
				}
				break
			}
			peer_session_destroy(&ps, allocator)
			return {}, nil, merr
		}
		apply_wire_message(&ps, msg, allocator)
		message_destroy(&msg, allocator)
		if has_extension(ps.remote) && ps.got_extended && !want_metadata {
			if bitfield_any(ps.bitfield) {
				break
			}
		}
	}

	if want_metadata && ps.got_extended {
		raw, ok, merr := fetch_metadata(sock, ps.extended, want_hash, allocator)
		if ok {
			metadata = raw
		} else if merr.kind != .None {
			if merr.message != "" {
				delete(merr.message, allocator)
			}
		}
	}

	return ps, metadata, {}
}

@(private)
send_extended_handshake :: proc(sock: net.TCP_Socket, listen_port: u16, allocator := context.allocator) -> Error {
	payload, perr := encode_extended_handshake(listen_port, allocator)
	if perr.kind != .None {
		return perr
	}
	defer delete(payload, allocator)
	return write_message(sock, Message{id = .Extended, payload = payload}, allocator)
}

@(private)
bitfield_any :: proc(bf: Bitfield) -> bool {
	for b in bf.bits {
		if b != 0 {
			return true
		}
	}
	return false
}

@(private)
apply_wire_message :: proc(ps: ^Peer_Session, msg: Message, allocator := context.allocator) {
	if msg.keep_alive {
		return
	}
	switch msg.id {
	case .Choke:
		ps.peer_choking = true
	case .Unchoke:
		ps.peer_choking = false
	case .Interested, .Not_Interested, .Request, .Cancel, .Port, .Piece:
	case .Have:
		if index, ok := decode_have(msg.payload); ok {
			bitfield_set(&ps.bitfield, int(index))
		}
	case .Bitfield:
		count := ps.bitfield.count
		if count <= 0 {
			count = len(msg.payload) * 8
		}
		bitfield_destroy(&ps.bitfield, allocator)
		ps.bitfield = bitfield_from_bytes(msg.payload, count, allocator)
	case .Extended:
		if len(msg.payload) > 0 && msg.payload[0] == EXT_HANDSHAKE_ID {
			ext, err := decode_extended_handshake(msg.payload, allocator)
			if err.kind == .None {
				extended_destroy(&ps.extended, allocator)
				ps.extended = ext
				ps.got_extended = true
			} else if err.message != "" {
				delete(err.message, allocator)
			}
		}
	}
}

@(private)
swarm_complete :: proc(s: ^Swarm) -> bool {
	for i in 0 ..< s.have.count {
		if !bitfield_has(s.have, i) {
			return false
		}
	}
	return s.have.count > 0
}

@(private)
swarm_next_endpoint :: proc(s: ^Swarm) -> (ep: net.Endpoint, label: string, ok: bool) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if swarm_complete(s) || s.next_ep >= len(s.endpoints) || s.peers_tried >= MAX_PEER_TRIES {
		return {}, "", false
	}
	ep = s.endpoints[s.next_ep]
	s.next_ep += 1
	s.peers_tried += 1
	label = net.endpoint_to_string(ep, s.allocator)
	return ep, label, true
}

@(private)
swarm_claim_piece :: proc(s: ^Swarm, peer_bf: Bitfield) -> (index: int, ok: bool) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if swarm_complete(s) {
		return 0, false
	}
	for i in 0 ..< s.have.count {
		if bitfield_has(s.have, i) || bitfield_has(s.claimed, i) {
			continue
		}
		if bitfield_any(peer_bf) && !bitfield_has(peer_bf, i) {
			continue
		}
		bitfield_set(&s.claimed, i)
		return i, true
	}
	return 0, false
}

@(private)
swarm_unclaim :: proc(s: ^Swarm, index: int) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if index >= 0 && index < s.claimed.count {
		byte_i := index / 8
		bit := u8(0x80) >> uint(index % 8)
		s.claimed.bits[byte_i] &= ~bit
	}
}

@(private)
swarm_finish_piece :: proc(s: ^Swarm, index: int, data: []byte, allocator := context.allocator) -> Error {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if bitfield_has(s.have, index) {
		swarm_unclaim_locked(s, index)
		return {}
	}
	if serr := storage.write_piece(s.store, index, data, allocator); serr.kind != .None {
		swarm_unclaim_locked(s, index)
		return peer_fail(.IO, storage.error_string(serr), allocator)
	}
	bitfield_set(&s.have, index)
	swarm_unclaim_locked(s, index)
	s.pieces_got += 1
	return {}
}

@(private)
swarm_unclaim_locked :: proc(s: ^Swarm, index: int) {
	if index >= 0 && index < s.claimed.count {
		byte_i := index / 8
		bit := u8(0x80) >> uint(index % 8)
		s.claimed.bits[byte_i] &= ~bit
	}
}

@(private)
swarm_set_active :: proc(s: ^Swarm, slot: int, endpoint, client: string, on: bool) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if slot < 0 || slot >= MAX_CONCURRENT_PEERS {
		return
	}
	if s.active_on[slot] {
		delete(s.active[slot].endpoint, s.allocator)
		delete(s.active[slot].client, s.allocator)
		s.active[slot] = {}
		s.active_on[slot] = false
	}
	if on {
		s.active[slot] = Active_Peer{
			endpoint = strings.clone(endpoint, s.allocator),
			client   = strings.clone(client, s.allocator),
		}
		s.active_on[slot] = true
	}
}

@(private)
swarm_collect_active :: proc(s: ^Swarm) -> []Active_Peer {
	n := 0
	for i in 0 ..< MAX_CONCURRENT_PEERS {
		if s.active_on[i] {
			n += 1
		}
	}
	out := make([]Active_Peer, n, context.temp_allocator)
	j := 0
	for i in 0 ..< MAX_CONCURRENT_PEERS {
		if !s.active_on[i] {
			continue
		}
		out[j] = Active_Peer{
			endpoint = strings.clone(s.active[i].endpoint, context.temp_allocator),
			client   = strings.clone(s.active[i].client, context.temp_allocator),
		}
		j += 1
	}
	return out
}

@(private)
swarm_emit :: proc(s: ^Swarm, event: Progress_Event, peer_label := "", peer_client := "") {
	if s.on_progress == nil {
		return
	}
	sync.lock(&s.mu)
	total := s.have.count
	done_n := 0
	done_bytes: i64
	have_flags := make([]bool, total, context.temp_allocator)
	for i in 0 ..< total {
		if bitfield_has(s.have, i) {
			done_n += 1
			done_bytes += metainfo.piece_length_at(s.info, i)
			have_flags[i] = true
		}
	}
	files := metainfo.file_progress(s.info, have_flags, context.temp_allocator)
	active := swarm_collect_active(s)
	p := Progress{
		event        = event,
		pieces_done  = done_n,
		pieces_total = total,
		bytes_done   = done_bytes,
		bytes_total  = metainfo.total_length(s.info),
		peer         = peer_label,
		peer_client  = peer_client,
		peers_tried  = s.peers_tried,
		peers_live   = s.peers_live,
		peers_failed = s.peers_failed,
		active       = active,
		files        = files,
	}
	sync.unlock(&s.mu)
	s.on_progress(p, s.progress_user)
}

@(private)
swarm_worker :: proc(t: ^thread.Thread) {
	s := cast(^Swarm)t.data
	slot := t.user_index
	allocator := s.allocator

	for {
		if swarm_complete(s) {
			break
		}
		ep, label, ok := swarm_next_endpoint(s)
		if !ok {
			break
		}
		swarm_emit(s, .Peer_Try, label, "")

		ps, _, cerr := connect_session(
			ep,
			s.local,
			s.have.count,
			s.listen_port,
			false,
			s.local.info_hash,
			HANDSHAKE_TIMEOUT,
			allocator,
		)
		if cerr.kind != .None {
			sync.lock(&s.mu)
			s.peers_failed += 1
			sync.unlock(&s.mu)
			if cerr.message != "" {
				delete(cerr.message, allocator)
			}
			swarm_emit(s, .Peer_Fail, label, "")
			delete(label, allocator)
			continue
		}

		client_name := ps.extended.client if ps.got_extended else ""
		sync.lock(&s.mu)
		s.peers_live += 1
		sync.unlock(&s.mu)
		swarm_set_active(s, slot, label, client_name, true)
		swarm_emit(s, .Peer_Live, label, client_name)

		_, _ = leech_from_peer(s, &ps, label, slot, allocator)

		swarm_set_active(s, slot, "", "", false)
		peer_session_destroy(&ps, allocator)
		delete(label, allocator)

		if swarm_complete(s) {
			break
		}
	}
}

@(private)
leech_from_peer :: proc(
	s: ^Swarm,
	ps: ^Peer_Session,
	peer_label: string,
	slot: int,
	allocator := context.allocator,
) -> (
	pieces: int,
	err: Error,
) {
	if !ps.am_interested {
		if werr := write_id(ps.sock, .Interested, allocator); werr.kind != .None {
			return 0, werr
		}
		ps.am_interested = true
	}
	if ps.peer_choking {
		if uerr := wait_unchoke(ps, allocator); uerr.kind != .None {
			return 0, uerr
		}
	}

	for {
		if swarm_complete(s) {
			return pieces, {}
		}
		index, ok := swarm_claim_piece(s, ps.bitfield)
		if !ok {
			return pieces, {}
		}

		plen := int(metainfo.piece_length_at(s.info, index))
		if plen <= 0 {
			swarm_unclaim(s, index)
			continue
		}
		buf := make([]byte, plen, allocator)
		got := make([]bool, (plen + BLOCK_SIZE - 1) / BLOCK_SIZE, allocator)

		derr := download_piece(ps, u32(index), buf, got, allocator)
		if derr.kind != .None {
			delete(buf, allocator)
			delete(got, allocator)
			swarm_unclaim(s, index)
			return pieces, derr
		}
		if !metainfo.verify_piece(s.info, index, buf) {
			delete(buf, allocator)
			delete(got, allocator)
			swarm_unclaim(s, index)
			return pieces, peer_fail(.Protocol, "piece hash mismatch", allocator)
		}
		ferr := swarm_finish_piece(s, index, buf, allocator)
		delete(buf, allocator)
		delete(got, allocator)
		if ferr.kind != .None {
			return pieces, ferr
		}
		_ = write_have(ps.sock, u32(index), allocator)
		pieces += 1

		client_name := ps.extended.client if ps.got_extended else ""
		swarm_emit(s, .Piece, peer_label, client_name)
	}
}

@(private)
wait_unchoke :: proc(ps: ^Peer_Session, allocator := context.allocator) -> Error {
	for _ in 0 ..< DOWNLOAD_MSGS {
		if !ps.peer_choking {
			return {}
		}
		msg, err := read_message(ps.sock, allocator)
		if err.kind != .None {
			return err
		}
		#partial switch msg.id {
		case .Unchoke:
			ps.peer_choking = false
		case .Choke:
			ps.peer_choking = true
		case .Have:
			if index, ok := decode_have(msg.payload); ok {
				bitfield_set(&ps.bitfield, int(index))
			}
		case .Bitfield:
			count := ps.bitfield.count
			if count <= 0 {
				count = len(msg.payload) * 8
			}
			bitfield_destroy(&ps.bitfield, allocator)
			ps.bitfield = bitfield_from_bytes(msg.payload, count, allocator)
		}
		message_destroy(&msg, allocator)
		if !ps.peer_choking {
			return {}
		}
	}
	return peer_fail(.Timeout, "timed out waiting for unchoke", allocator)
}

@(private)
download_piece :: proc(
	ps: ^Peer_Session,
	index: u32,
	buf: []byte,
	got: []bool,
	allocator := context.allocator,
) -> Error {
	pending := 0
	next_begin := 0
	received := 0
	blocks := len(got)

	for received < blocks {
		for pending < MAX_PIPELINE && next_begin < len(buf) {
			if ps.peer_choking {
				break
			}
			block_i := next_begin / BLOCK_SIZE
			if got[block_i] {
				next_begin += BLOCK_SIZE
				continue
			}
			length := BLOCK_SIZE
			if next_begin + length > len(buf) {
				length = len(buf) - next_begin
			}
			if werr := write_request(ps.sock, index, u32(next_begin), u32(length), allocator); werr.kind != .None {
				return werr
			}
			pending += 1
			next_begin += length
		}

		if ps.peer_choking {
			if uerr := wait_unchoke(ps, allocator); uerr.kind != .None {
				return uerr
			}
			pending = 0
			next_begin = 0
			for i in 0 ..< blocks {
				if !got[i] {
					next_begin = i * BLOCK_SIZE
					break
				}
			}
			continue
		}

		msg, err := read_message(ps.sock, allocator)
		if err.kind != .None {
			return err
		}
		defer message_destroy(&msg, allocator)

		if msg.keep_alive {
			continue
		}
		switch msg.id {
		case .Choke:
			ps.peer_choking = true
			pending = 0
		case .Unchoke:
			ps.peer_choking = false
		case .Have:
			if idx, ok := decode_have(msg.payload); ok {
				bitfield_set(&ps.bitfield, int(idx))
			}
		case .Bitfield:
			count := ps.bitfield.count
			if count <= 0 {
				count = len(msg.payload) * 8
			}
			bitfield_destroy(&ps.bitfield, allocator)
			ps.bitfield = bitfield_from_bytes(msg.payload, count, allocator)
		case .Piece:
			pidx, begin, block, ok := decode_piece(msg.payload)
			if !ok || pidx != index {
				continue
			}
			if int(begin) + len(block) > len(buf) {
				return peer_fail(.Protocol, "piece block out of range", allocator)
			}
			bi := int(begin) / BLOCK_SIZE
			if bi < len(got) && !got[bi] {
				copy(buf[begin:], block)
				got[bi] = true
				received += 1
				pending -= 1
				if pending < 0 {
					pending = 0
				}
			}
		case .Extended, .Interested, .Not_Interested, .Request, .Cancel, .Port:
		}
	}
	return {}
}

// Download as much as possible from a list of peers in parallel.
download_torrent :: proc(
	endpoints: []net.Endpoint,
	local: Handshake,
	info: metainfo.Info,
	store: ^storage.Store,
	listen_port: u16 = 0,
	on_progress: Progress_Proc = nil,
	progress_user: rawptr = nil,
	allocator := context.allocator,
) -> (
	pieces: int,
	err: Error,
) {
	total := metainfo.piece_count(info)
	if total == 0 {
		return 0, peer_fail(.Invalid, "no pieces to download", allocator)
	}

	swarm := Swarm{
		info          = info,
		store         = store,
		local         = local,
		listen_port   = listen_port,
		have          = bitfield_make(total, allocator),
		claimed       = bitfield_make(total, allocator),
		endpoints     = endpoints,
		on_progress   = on_progress,
		progress_user = progress_user,
		allocator     = allocator,
	}
	defer {
		bitfield_destroy(&swarm.have, allocator)
		bitfield_destroy(&swarm.claimed, allocator)
		for i in 0 ..< MAX_CONCURRENT_PEERS {
			if swarm.active_on[i] {
				delete(swarm.active[i].endpoint, allocator)
				delete(swarm.active[i].client, allocator)
			}
		}
	}

	workers := min(MAX_CONCURRENT_PEERS, max(1, len(endpoints)))
	threads := make([]^thread.Thread, workers, allocator)
	defer delete(threads, allocator)

	swarm_emit(&swarm, .Peer_Try, "", "")

	for i in 0 ..< workers {
		t := thread.create(swarm_worker)
		t.data = &swarm
		t.user_index = i
		threads[i] = t
		thread.start(t)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	pieces = swarm.pieces_got
	if !swarm_complete(&swarm) {
		return pieces, peer_fail(.Protocol, "download incomplete", allocator)
	}
	return pieces, {}
}
