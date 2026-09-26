/*
	HTTP control-plane API backed by odin-http (laytan/odin-http).
	Bound to a session.Engine for multi-torrent daemon control.
*/
package api

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strconv"
import http "deps:http"
import "avalanche:session"

DEFAULT_API_PORT :: u16(8080)

Server_Config :: struct {
	host:   net.Address,
	port:   u16,
	output: string, // default download root for POST /api/torrents
}

@(private)
g_engine: ^session.Engine
@(private)
g_output: string

Torrent_JSON :: struct {
	id:           u64    `json:"id"`,
	name:         string `json:"name"`,
	infohash:     string `json:"infohash"`,
	state:        string `json:"state"`,
	pieces_done:  int    `json:"pieces_done"`,
	pieces_total: int    `json:"pieces_total"`,
	bytes_done:   i64    `json:"bytes_done"`,
	bytes_total:  i64    `json:"bytes_total"`,
	down_rate:    i64    `json:"down_rate"`,
	up_rate:      i64    `json:"up_rate"`,
	peers_tried:  int    `json:"peers_tried"`,
	peers_live:   int    `json:"peers_live"`,
	peers_failed: int    `json:"peers_failed"`,
	peers_active: int    `json:"peers_active"`,
	error:        string `json:"error,omitempty"`,
	output:       string `json:"output"`,
}

File_JSON :: struct {
	name:  string `json:"name"`,
	done:  i64    `json:"done"`,
	total: i64    `json:"total"`,
}

Peer_JSON :: struct {
	endpoint:  string `json:"endpoint"`,
	client:    string `json:"client"`,
	down_rate: i64    `json:"down_rate"`,
}

Detail_JSON :: struct {
	id:        u64         `json:"id"`,
	down_rate: i64         `json:"down_rate"`,
	up_rate:   i64         `json:"up_rate"`,
	files:     []File_JSON `json:"files"`,
	peers:     []Peer_JSON `json:"peers"`,
}

Add_Request :: struct {
	magnet: string `json:"magnet"`,
	path:   string `json:"path"`,
	output: string `json:"output"`,
}

Error_Body :: struct {
	error: string `json:"error"`,
}

Status_Body :: struct {
	status: string `json:"status"`,
}

Add_Response :: struct {
	id: u64 `json:"id"`,
}

status_to_json :: proc(st: session.Torrent_Status) -> Torrent_JSON {
	return Torrent_JSON{
		id           = u64(st.id),
		name         = st.name,
		infohash     = st.infohash,
		state        = session.torrent_state_string(st.state),
		pieces_done  = st.pieces_done,
		pieces_total = st.pieces_total,
		bytes_done   = st.bytes_done,
		bytes_total  = st.bytes_total,
		down_rate    = st.down_rate,
		up_rate      = st.up_rate,
		peers_tried  = st.peers_tried,
		peers_live   = st.peers_live,
		peers_failed = st.peers_failed,
		peers_active = st.peers_active,
		error        = st.error,
		output       = st.output,
	}
}

detail_to_json :: proc(d: session.Torrent_Detail) -> Detail_JSON {
	files := make([]File_JSON, len(d.files))
	for f, i in d.files {
		files[i] = File_JSON{name = f.name, done = f.done, total = f.total}
	}
	peers := make([]Peer_JSON, len(d.peers))
	for p, i in d.peers {
		peers[i] = Peer_JSON{endpoint = p.endpoint, client = p.client, down_rate = p.down_rate}
	}
	return Detail_JSON{
		id        = u64(d.id),
		down_rate = d.down_rate,
		up_rate   = d.up_rate,
		files     = files,
		peers     = peers,
	}
}

// listen_and_serve blocks until the HTTP server shuts down.
listen_and_serve :: proc(eng: ^session.Engine, cfg: Server_Config) -> net.Network_Error {
	assert(eng != nil)
	g_engine = eng
	g_output = cfg.output if cfg.output != "" else "downloads"

	// Prefer logger from main; only install a fallback if none is set.
	if context.logger.procedure == nil {
		context.logger = log.create_console_logger(.Info)
	}

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/health", http.handler(handle_health))
	http.route_get(&router, "/api/torrents", http.handler(handle_list))
	http.route_get(&router, "/api/torrents/(%d+)/details", http.handler(handle_details))
	http.route_get(&router, "/api/torrents/(%d+)", http.handler(handle_get))
	http.route_post(&router, "/api/torrents", http.handler(handle_add))
	http.route_post(&router, "/api/torrents/(%d+)/stop", http.handler(handle_stop))
	http.route_delete(&router, "/api/torrents/(%d+)", http.handler(handle_remove))
	http.route_all(&router, "(.*)", http.handler(handle_not_found))

	handler := http.router_handler(&router)
	host: net.Address = cfg.host if cfg.host != nil else net.IP4_Loopback
	port := cfg.port if cfg.port != 0 else DEFAULT_API_PORT
	endpoint := net.Endpoint{address = host, port = int(port)}

	log.infof("avalanche api listening on http://%s", net.endpoint_to_string(endpoint, context.temp_allocator))
	return http.listen_and_serve(&s, handler, endpoint)
}

@(private)
handle_health :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	http.respond_json(res, Status_Body{status = "ok"})
}

@(private)
handle_list :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	list := session.engine_list(g_engine)
	defer {
		for &st in list {
			session.status_destroy(&st)
		}
		delete(list)
	}
	out := make([]Torrent_JSON, len(list))
	for st, i in list {
		out[i] = status_to_json(st)
	}
	http.respond_json(res, out)
}

@(private)
handle_get :: proc(req: ^http.Request, res: ^http.Response) {
	id, ok := parse_id_param(req)
	if !ok {
		http.respond_json(res, Error_Body{error = "invalid id"}, .Bad_Request)
		return
	}
	st, found := session.engine_status(g_engine, id)
	if !found {
		http.respond_json(res, Error_Body{error = "not found"}, .Not_Found)
		return
	}
	defer session.status_destroy(&st)
	http.respond_json(res, status_to_json(st))
}

@(private)
handle_details :: proc(req: ^http.Request, res: ^http.Response) {
	id, ok := parse_id_param(req)
	if !ok {
		http.respond_json(res, Error_Body{error = "invalid id"}, .Bad_Request)
		return
	}
	detail, found := session.engine_details(g_engine, id)
	if !found {
		http.respond_json(res, Error_Body{error = "not found"}, .Not_Found)
		return
	}
	defer session.detail_destroy(&detail)
	http.respond_json(res, detail_to_json(detail))
}

@(private)
handle_add :: proc(req: ^http.Request, res: ^http.Response) {
	http.body(req, user_data = res, cb = proc(user: rawptr, body: http.Body, err: http.Body_Error) {
		res := cast(^http.Response)user
		if err != nil {
			http.respond(res, http.body_error_status(err))
			return
		}
		payload: Add_Request
		if jerr := json.unmarshal_string(body, &payload); jerr != nil {
			http.respond_json(res, Error_Body{error = "invalid json"}, .Unprocessable_Content)
			return
		}
		out := payload.output if payload.output != "" else g_output
		id: session.Torrent_ID
		serr: session.Error
		if payload.magnet != "" {
			id, serr = session.engine_add_magnet(g_engine, payload.magnet, out)
		} else if payload.path != "" {
			id, serr = session.engine_add_torrent_file(g_engine, payload.path, out)
		} else {
			http.respond_json(res, Error_Body{error = "magnet or path required"}, .Bad_Request)
			return
		}
		if serr.kind != .None {
			msg := session.error_string(serr)
			if serr.message != "" {
				delete(serr.message)
			}
			http.respond_json(res, Error_Body{error = msg}, .Bad_Request)
			return
		}
		http.respond_json(res, Add_Response{id = u64(id)}, .Created)
	})
}

@(private)
handle_stop :: proc(req: ^http.Request, res: ^http.Response) {
	id, ok := parse_id_param(req)
	if !ok {
		http.respond_json(res, Error_Body{error = "invalid id"}, .Bad_Request)
		return
	}
	st, found := session.engine_status(g_engine, id)
	if !found {
		http.respond_json(res, Error_Body{error = "not found"}, .Not_Found)
		return
	}
	session.status_destroy(&st)
	session.engine_stop(g_engine, id)
	http.respond_json(res, Status_Body{status = "stopping"})
}

@(private)
handle_remove :: proc(req: ^http.Request, res: ^http.Response) {
	id, ok := parse_id_param(req)
	if !ok {
		http.respond_json(res, Error_Body{error = "invalid id"}, .Bad_Request)
		return
	}
	st, found := session.engine_status(g_engine, id)
	if !found {
		http.respond_json(res, Error_Body{error = "not found"}, .Not_Found)
		return
	}
	session.status_destroy(&st)
	session.engine_stop(g_engine, id)
	session.engine_remove(g_engine, id)
	http.respond_json(res, Status_Body{status = "removed"})
}

@(private)
handle_not_found :: proc(req: ^http.Request, res: ^http.Response) {
	path := req.url_params[0] if len(req.url_params) > 0 else ""
	http.respond_json(res, Error_Body{error = fmt.tprintf("not found: %s", path)}, .Not_Found)
}

@(private)
parse_id_param :: proc(req: ^http.Request) -> (session.Torrent_ID, bool) {
	if len(req.url_params) == 0 {
		return 0, false
	}
	n, ok := strconv.parse_u64(req.url_params[0])
	if !ok || n == 0 {
		return 0, false
	}
	return session.Torrent_ID(n), true
}
