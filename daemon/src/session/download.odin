package session

import "core:net"
import "core:strings"
import "avalanche:metainfo"
import "avalanche:peer"
import "avalanche:storage"
import "avalanche:tracker"

MAX_ANNOUNCE_PEERS :: 200
MAX_METADATA_PEERS :: 12

Download_Result :: struct {
	pieces: int,
	path:   string,
}

session_fail :: proc(kind: Error_Kind, msg: string, allocator := context.allocator) -> Error {
	return Error{kind = kind, message = strings.clone(msg, allocator)}
}

collect_swarm :: proc(
	client: Client,
	magnet: metainfo.Magnet,
	allocator := context.allocator,
) -> (
	peers: [dynamic]tracker.Peer_Addr,
	err: Error,
) {
	req := announce_request(client, magnet)
	for url in magnet.trackers {
		if !tracker.is_udp_tracker(url) && !tracker.is_http_tracker(url) {
			continue
		}
		res, aerr := tracker.announce(url, req, allocator)
		if aerr.kind != .None {
			if aerr.message != "" {
				delete(aerr.message, allocator)
			}
			continue
		}
		for p in res.peers {
			exists := false
			for have in peers {
				if have.endpoint == p.endpoint {
					exists = true
					break
				}
			}
			if !exists {
				append(&peers, p)
				if len(peers) >= MAX_ANNOUNCE_PEERS {
					tracker.announce_destroy(&res)
					return peers, {}
				}
			}
		}
		tracker.announce_destroy(&res)
	}
	return peers, {}
}

ensure_metadata :: proc(
	client: Client,
	tor: ^Torrent_Session,
	peers: []tracker.Peer_Addr,
	allocator := context.allocator,
) -> Error {
	if tor.has_meta {
		return {}
	}
	local := peer.make_handshake(transmute([20]u8)tor.magnet.info_hash, client.peer_id)
	tried := 0
	for p in peers {
		if tried >= MAX_METADATA_PEERS {
			break
		}
		tried += 1
		ps, raw, err := peer.connect_session(
			p.endpoint,
			local,
			0,
			client.listen_port,
			true,
			transmute([20]u8)tor.magnet.info_hash,
			peer.HANDSHAKE_TIMEOUT,
			allocator,
		)
		if err.kind != .None {
			if err.message != "" {
				delete(err.message, allocator)
			}
			peer.peer_session_destroy(&ps, allocator)
			continue
		}
		if len(raw) == 0 {
			peer.peer_session_destroy(&ps, allocator)
			continue
		}
		info, ih, ierr := metainfo.parse_info(raw, allocator)
		delete(raw, allocator)
		peer.peer_session_destroy(&ps, allocator)
		if ierr.kind != .None {
			continue
		}
		if ih != tor.magnet.info_hash {
			metainfo.info_destroy(&info, allocator)
			continue
		}
		tor.meta.info = info
		tor.meta.info_hash = ih
		tor.has_meta = true
		return {}
	}
	return session_fail(.Invalid, "could not fetch torrent metadata from peers", allocator)
}

download :: proc(
	client: ^Client,
	tor: ^Torrent_Session,
	output: string,
	on_progress: peer.Progress_Proc = nil,
	progress_user: rawptr = nil,
	allocator := context.allocator,
) -> (
	result: Download_Result,
	err: Error,
) {
	if client == nil || tor == nil {
		return {}, session_fail(.Invalid, "nil session", allocator)
	}
	root := output if output != "" else "downloads"

	peers, perr := collect_swarm(client^, tor.magnet, allocator)
	defer delete(peers)
	_ = perr
	if len(peers) == 0 {
		return {}, session_fail(.Invalid, "no peers from trackers", allocator)
	}

	if merr := ensure_metadata(client^, tor, peers[:], allocator); merr.kind != .None {
		return {}, merr
	}

	store, serr := storage.open(root, tor.meta.info, allocator)
	if serr.kind != .None {
		msg := storage.error_string(serr)
		if serr.message != "" {
			delete(serr.message, allocator)
		}
		return {}, session_fail(.Invalid, msg, allocator)
	}
	defer storage.close(&store, allocator)

	local := peer.make_handshake(transmute([20]u8)tor.meta.info_hash, client.peer_id)
	endpoints: [dynamic]net.Endpoint
	defer delete(endpoints)
	for p in peers {
		append(&endpoints, p.endpoint)
	}

	n, derr := peer.download_torrent(
		endpoints[:],
		local,
		tor.meta.info,
		&store,
		client.listen_port,
		on_progress,
		progress_user,
		nil,
		nil,
		allocator,
	)
	result.pieces = n
	result.path = strings.clone(root, allocator)
	if derr.kind != .None {
		msg := peer.error_string(derr)
		if derr.message != "" {
			out := session_fail(.Invalid, msg, allocator)
			delete(derr.message, allocator)
			return result, out
		}
		return result, session_fail(.Invalid, msg, allocator)
	}
	return result, {}
}