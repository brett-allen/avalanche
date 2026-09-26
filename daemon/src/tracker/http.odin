package tracker

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import curl "vendor:curl"

USER_AGENT :: "Avalanche/0.1"

Http_Response :: struct {
	status: int,
	body:   []byte,
}

@(private)
Http_Body :: struct {
	buf:       [dynamic]u8,
	allocator: mem.Allocator,
}

@(private)
http_write :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	body := cast(^Http_Body)userdata
	context.allocator = body.allocator
	n := int(size * nmemb)
	if n == 0 {
		return 0
	}
	append(&body.buf, ..mem.slice_ptr(ptr, n))
	return size * nmemb
}

http_get :: proc(
	url: string,
	timeout: time.Duration = 8 * time.Second,
	allocator := context.allocator,
) -> (
	resp: Http_Response,
	err: Error,
) {
	handle := curl.easy_init()
	if handle == nil {
		return {}, Error{kind = .Init_Failed}
	}
	defer curl.easy_cleanup(handle)

	out: Http_Body
	out.allocator = allocator
	out.buf.allocator = allocator

	errbuf: [curl.ERROR_SIZE]u8
	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	ua := strings.clone_to_cstring(USER_AGENT, context.temp_allocator)

	curl.easy_setopt(handle, curl.option.URL, url_c)
	curl.easy_setopt(handle, curl.option.TIMEOUT, c.long(time.duration_seconds(timeout)))
	curl.easy_setopt(handle, curl.option.FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(handle, curl.option.USERAGENT, ua)
	curl.easy_setopt(handle, curl.option.ERRORBUFFER, raw_data(errbuf[:]))
	curl.easy_setopt(handle, curl.option.WRITEFUNCTION, http_write)
	curl.easy_setopt(handle, curl.option.WRITEDATA, &out)

	code := curl.easy_perform(handle)
	if code != .E_OK {
		delete(out.buf)
		msg := strings.clone_from_cstring(cstring(&errbuf[0]), allocator)
		if msg == "" {
			msg = strings.clone("curl request failed", allocator)
		}
		return {}, Error{kind = .Request_Failed, message = msg}
	}

	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	resp.status = int(status)
	resp.body = out.buf[:]

	if status < 200 || status >= 300 {
		return resp, Error{kind = .Bad_Status, status = resp.status}
	}
	return resp, {}
}

http_response_destroy :: proc(resp: ^Http_Response) {
	if resp == nil {
		return
	}
	delete(resp.body)
	resp^ = {}
}

announce_http :: proc(
	url: string,
	req: Announce_Request,
	allocator := context.allocator,
) -> (
	res: Announce_Response,
	err: Error,
) {
	announce_url := build_announce_url(url, req, context.temp_allocator)
	resp: Http_Response
	resp, err = http_get(announce_url, 8 * time.Second, allocator)
	defer http_response_destroy(&resp)
	if err.kind != .None {
		return {}, err
	}

	return parse_announce_body(resp.body, allocator)
}

@(private)
build_announce_url :: proc(base: string, req: Announce_Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, base)
	strings.write_byte(&b, '?' if !strings.contains(base, "?") else '&')

	info_hash := req.info_hash
	peer_id := req.peer_id
	write_query_bytes(&b, "info_hash", info_hash[:])
	strings.write_byte(&b, '&')
	write_query_bytes(&b, "peer_id", peer_id[:])
	fmt.sbprintf(
		&b,
		"&port=%d&uploaded=%d&downloaded=%d&left=%d&compact=1&numwant=50",
		int(req.port),
		req.uploaded,
		req.downloaded,
		req.left,
	)
	switch req.event {
	case .None:
	case .Started:
		strings.write_string(&b, "&event=started")
	case .Completed:
		strings.write_string(&b, "&event=completed")
	case .Stopped:
		strings.write_string(&b, "&event=stopped")
	}
	return strings.to_string(b)
}

@(private)
write_query_bytes :: proc(b: ^strings.Builder, key: string, value: []byte) {
	strings.write_string(b, key)
	strings.write_byte(b, '=')
	strings.write_string(b, percent_encode_bytes(value, context.temp_allocator))
}

percent_encode_bytes :: proc(data: []byte, allocator := context.allocator) -> string {
	hex_digits := "0123456789ABCDEF"
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(data) * 3)
	for byte in data {
		switch byte {
		case 'A'..='Z', 'a'..='z', '0'..='9', '-', '_', '.', '~':
			strings.write_byte(&b, byte)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex_digits[byte >> 4])
			strings.write_byte(&b, hex_digits[byte & 0xf])
		}
	}
	return strings.to_string(b)
}

curl_version :: proc() -> string {
	return string(curl.version())
}
