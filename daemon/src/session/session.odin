/*
	Client session: peer id, listen port, and the torrents we are running.
*/
package session

import "core:crypto"
import "core:log"
import "avalanche:dht"
import "avalanche:metainfo"
import "avalanche:tracker"

PEER_ID_PREFIX :: "-AV0001-"
DEFAULT_PORT   :: u16(6881)

Error_Kind :: enum {
	None,
	Not_Implemented,
	Invalid,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

Client :: struct {
	peer_id:     [20]u8,
	listen_port: u16,
	dht:         ^dht.Node,
}

Torrent_Session :: struct {
	magnet:   metainfo.Magnet,
	meta:     metainfo.Torrent,
	has_meta: bool,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Not_Implemented:
		return "session: not implemented"
	case .Invalid:
		return err.message if err.message != "" else "session: invalid"
	}
	return "session: unknown error"
}

client_make :: proc(port: u16 = DEFAULT_PORT) -> Client {
	listen := port if port != 0 else DEFAULT_PORT
	client := Client{
		peer_id     = make_peer_id(),
		listen_port = listen,
	}
	node, derr := dht.node_make(listen)
	if derr.kind == .None {
		client.dht = node
		log.infof("dht: listening on udp/%d", int(node.port))
	} else {
		log.warnf("dht: disabled (%s)", derr.message if derr.message != "" else "init failed")
		if derr.message != "" {
			delete(derr.message)
		}
	}
	return client
}

destroy :: proc(client: ^Client) {
	if client == nil {
		return
	}
	if client.dht != nil {
		dht.node_destroy(client.dht)
		client.dht = nil
	}
	client^ = {}
}

torrent_destroy :: proc(tor: ^Torrent_Session, allocator := context.allocator) {
	if tor == nil {
		return
	}
	metainfo.magnet_destroy(&tor.magnet, allocator)
	metainfo.destroy(&tor.meta, allocator)
	tor^ = {}
}

make_peer_id :: proc() -> (id: [20]u8) {
	prefix := transmute([]u8)string(PEER_ID_PREFIX)
	copy(id[:], prefix)
	crypto.rand_bytes(id[len(PEER_ID_PREFIX):])
	return
}

add_torrent_file :: proc(client: ^Client, path: string, allocator := context.allocator) -> (tor: Torrent_Session, err: Error) {
	return {}, Error{kind = .Not_Implemented}
}

add_magnet :: proc(client: ^Client, uri: string, allocator := context.allocator) -> (tor: Torrent_Session, err: Error) {
	_ = client
	magnet, merr := metainfo.parse_magnet(uri, allocator)
	if merr.kind != .None {
		return {}, Error{kind = .Invalid, message = metainfo.error_string(merr)}
	}
	tor.magnet = magnet

	for source in magnet.sources {
		if !tracker.is_http_tracker(source) {
			continue
		}
		resp, herr := tracker.http_get(source)
		if herr.kind != .None {
			if herr.message != "" {
				delete(herr.message, allocator)
			}
			tracker.http_response_destroy(&resp)
			continue
		}
		meta, terr := metainfo.parse_torrent(resp.body, allocator)
		tracker.http_response_destroy(&resp)
		if terr.kind != .None {
			continue
		}
		if meta.info_hash != magnet.info_hash {
			metainfo.destroy(&meta, allocator)
			continue
		}
		tor.meta = meta
		tor.has_meta = true
		break
	}
	return tor, {}
}

announce_request :: proc(client: Client, magnet: metainfo.Magnet) -> tracker.Announce_Request {
	// Unknown size must NOT announce left=0 (that claims we're a seed).
	left := magnet.exact_length
	if left <= 0 {
		left = 1 << 40
	}
	return tracker.Announce_Request{
		info_hash  = magnet.info_hash,
		peer_id    = client.peer_id,
		port       = client.listen_port,
		left       = left,
		event      = .Started,
		compact    = true,
	}
}
