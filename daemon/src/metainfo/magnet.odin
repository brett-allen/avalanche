package metainfo

import "core:encoding/base32"
import "core:encoding/hex"
import "core:net"
import "core:strconv"
import "core:strings"

Magnet :: struct {
	info_hash:    Info_Hash,
	display:      string,
	exact_length: i64,
	trackers:     [dynamic]string,
	webseeds:     [dynamic]string,
	sources:      [dynamic]string,
}

parse_magnet :: proc(uri: string, allocator := context.allocator) -> (magnet: Magnet, err: Error) {
	if uri == "" {
		return {}, Error{kind = .Empty_Input}
	}
	if !is_magnet(uri) {
		return {}, Error{kind = .Invalid, message = "not a magnet URI"}
	}

	magnet.trackers.allocator = allocator
	magnet.webseeds.allocator = allocator
	magnet.sources.allocator = allocator
	defer if err.kind != .None {
		magnet_destroy(&magnet, allocator)
	}

	rest := uri[len("magnet:"):]
	if len(rest) == 0 || rest[0] != '?' {
		err = Error{kind = .Invalid, message = "magnet URI missing query"}
		return {}, err
	}
	query := rest[1:]

	got_hash := false
	for param in strings.split_iterator(&query, "&") {
		if param == "" {
			continue
		}
		eq := strings.index_byte(param, '=')
		raw_key := param if eq < 0 else param[:eq]
		raw_val := "" if eq < 0 else param[eq + 1:]

		key := decode_query_component(raw_key, context.temp_allocator) or_else raw_key
		val := decode_query_component(raw_val, allocator) or_else strings.clone(raw_val, allocator)

		switch ascii_lower_eq(key, "xt") {
		case true:
			hash, hash_ok := parse_exact_topic(val)
			delete(val, allocator)
			if hash_ok {
				magnet.info_hash = hash
				got_hash = true
			}
		case false:
			if ascii_lower_eq(key, "dn") {
				delete(magnet.display, allocator)
				magnet.display = val
			} else if ascii_lower_eq(key, "tr") {
				append(&magnet.trackers, val)
			} else if ascii_lower_eq(key, "ws") {
				append(&magnet.webseeds, val)
			} else if ascii_lower_eq(key, "xs") || ascii_lower_eq(key, "as") {
				append(&magnet.sources, val)
			} else if ascii_lower_eq(key, "xl") {
				n, n_ok := strconv.parse_i64(val, 10)
				delete(val, allocator)
				if n_ok && n >= 0 {
					magnet.exact_length = n
				}
			} else {
				delete(val, allocator)
			}
		}
	}

	if !got_hash {
		err = Error{kind = .Invalid, message = "magnet URI missing urn:btih infohash"}
		return {}, err
	}
	return magnet, {}
}

magnet_destroy :: proc(magnet: ^Magnet, allocator := context.allocator) {
	if magnet == nil {
		return
	}
	delete(magnet.display, allocator)
	for tracker in magnet.trackers {
		delete(tracker, allocator)
	}
	delete(magnet.trackers)
	for seed in magnet.webseeds {
		delete(seed, allocator)
	}
	delete(magnet.webseeds)
	for source in magnet.sources {
		delete(source, allocator)
	}
	delete(magnet.sources)
	magnet^ = {}
}

is_magnet :: proc(input: string) -> bool {
	return has_prefix_ci(input, "magnet:")
}

info_hash_hex :: proc(hash: Info_Hash, allocator := context.allocator) -> string {
	bytes := hash
	encoded, _ := hex.encode(bytes[:], allocator)
	return string(encoded)
}

// magnet_format rebuilds a magnet URI from structured fields (for session resume).
magnet_format :: proc(m: Magnet, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "magnet:?xt=urn:btih:")
	strings.write_string(&b, info_hash_hex(m.info_hash, context.temp_allocator))
	if m.display != "" {
		strings.write_string(&b, "&dn=")
		strings.write_string(&b, net.percent_encode(m.display, context.temp_allocator))
	}
	if m.exact_length > 0 {
		strings.write_string(&b, "&xl=")
		strings.write_i64(&b, m.exact_length)
	}
	for tr in m.trackers {
		strings.write_string(&b, "&tr=")
		strings.write_string(&b, net.percent_encode(tr, context.temp_allocator))
	}
	for ws in m.webseeds {
		strings.write_string(&b, "&ws=")
		strings.write_string(&b, net.percent_encode(ws, context.temp_allocator))
	}
	for src in m.sources {
		strings.write_string(&b, "&xs=")
		strings.write_string(&b, net.percent_encode(src, context.temp_allocator))
	}
	return strings.clone(strings.to_string(b), allocator)
}

@(private)
decode_query_component :: proc(s: string, allocator := context.allocator) -> (decoded: string, ok: bool) {
	replaced, was_alloc := strings.replace_all(s, "+", " ", context.temp_allocator)
	_ = was_alloc
	return net.percent_decode(replaced, allocator)
}

@(private)
parse_exact_topic :: proc(xt: string) -> (hash: Info_Hash, ok: bool) {
	topic := xt
	if has_prefix_ci(topic, "urn:btmh:") {
		return {}, false
	}
	if has_prefix_ci(topic, "urn:btih:") {
		topic = topic[len("urn:btih:"):]
	}
	return parse_info_hash(topic)
}

@(private)
parse_info_hash :: proc(s: string) -> (hash: Info_Hash, ok: bool) {
	if len(s) == 40 {
		decoded, hex_ok := hex.decode(transmute([]byte)s, context.temp_allocator)
		if !hex_ok || len(decoded) != 20 {
			return {}, false
		}
		copy(hash[:], decoded)
		return hash, true
	}
	if len(s) == 32 {
		decoded, berr := base32.decode(strings.to_upper(s, context.temp_allocator))
		if berr != .None || len(decoded) != 20 {
			return {}, false
		}
		copy(hash[:], decoded)
		delete(decoded)
		return hash, true
	}
	return {}, false
}

@(private)
has_prefix_ci :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if ascii_lower(s[i]) != ascii_lower(prefix[i]) {
			return false
		}
	}
	return true
}

@(private)
ascii_lower_eq :: proc(s, target: string) -> bool {
	if len(s) != len(target) {
		return false
	}
	for i in 0 ..< len(s) {
		if ascii_lower(s[i]) != ascii_lower(target[i]) {
			return false
		}
	}
	return true
}

@(private)
ascii_lower :: proc(c: byte) -> byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}
