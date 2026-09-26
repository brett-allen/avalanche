/*
	Tracker announce (BEP 3 HTTP/HTTPS, BEP 15 UDP).
	HTTPS goes through vendor:curl.
*/
package tracker

import "core:net"
import "avalanche:metainfo"

DEFAULT_PORT :: u16(6881)

Event :: enum {
	None,
	Started,
	Completed,
	Stopped,
}

Peer_Addr :: struct {
	endpoint: net.Endpoint,
}

Announce_Request :: struct {
	info_hash:  metainfo.Info_Hash,
	peer_id:    [20]u8,
	port:       u16,
	uploaded:   i64,
	downloaded: i64,
	left:       i64,
	event:      Event,
	compact:    bool,
}

Announce_Response :: struct {
	interval:     i64,
	min_interval: i64,
	complete:     i64,
	incomplete:   i64,
	peers:        [dynamic]Peer_Addr,
}

announce_destroy :: proc(res: ^Announce_Response) {
	if res == nil {
		return
	}
	delete(res.peers)
	res^ = {}
}

announce :: proc(url: string, req: Announce_Request, allocator := context.allocator) -> (Announce_Response, Error) {
	if is_udp_tracker(url) {
		return announce_udp(url, req, allocator)
	}
	if is_http_tracker(url) {
		return announce_http(url, req, allocator)
	}
	return {}, Error{kind = .Request_Failed, message = "unsupported tracker scheme"}
}

is_udp_tracker :: proc(url: string) -> bool {
	return has_prefix_ci(url, "udp://")
}
