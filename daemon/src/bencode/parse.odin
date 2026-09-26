package bencode

import "core:mem"
import "core:strings"

Parser :: struct {
	data:      []byte,
	off:       int,
	allocator: mem.Allocator,
}

@(private)
at_end :: proc(p: ^Parser) -> bool {
	return p.off >= len(p.data)
}

@(private)
peek :: proc(p: ^Parser) -> (b: byte, ok: bool) {
	if at_end(p) {
		return 0, false
	}
	return p.data[p.off], true
}

@(private)
eof_error :: proc(p: ^Parser) -> Error {
	return Error{kind = .Unexpected_Eof, offset = p.off}
}

@(private)
invalid :: proc(p: ^Parser, message: string) -> Error {
	return Error{kind = .Invalid, offset = p.off, message = message}
}

parse_value :: proc(p: ^Parser) -> (value: Value, err: Error) {
	b, ok := peek(p)
	if !ok {
		return nil, eof_error(p)
	}
	switch b {
	case 'i':
		return parse_int(p)
	case 'l':
		return parse_list(p)
	case 'd':
		return parse_dict(p)
	case '0'..='9':
		s: string
		s, err = parse_string(p)
		if err.kind != .None {
			return nil, err
		}
		return s, {}
	}
	return nil, invalid(p, "expected i, l, d, or a string")
}

skip_value :: proc(p: ^Parser) -> (err: Error) {
	b, ok := peek(p)
	if !ok {
		return eof_error(p)
	}
	switch b {
	case 'i':
		_, err = parse_int(p)
		return err
	case '0'..='9':
		return skip_string(p)
	case 'l':
		p.off += 1
		for {
			c, cok := peek(p)
			if !cok {
				return eof_error(p)
			}
			if c == 'e' {
				p.off += 1
				return {}
			}
			err = skip_value(p)
			if err.kind != .None {
				return err
			}
		}
	case 'd':
		p.off += 1
		for {
			c, cok := peek(p)
			if !cok {
				return eof_error(p)
			}
			if c == 'e' {
				p.off += 1
				return {}
			}
			err = skip_string(p)
			if err.kind != .None {
				return err
			}
			err = skip_value(p)
			if err.kind != .None {
				return err
			}
		}
	}
	return invalid(p, "expected i, l, d, or a string")
}

// raw_top_value returns a slice of `data` covering the bencoded value for `key`
// in the top-level dict. The slice is not copied.
raw_top_value :: proc(data: []byte, key: string) -> (raw: []byte, err: Error) {
	if len(data) == 0 {
		return nil, Error{kind = .Empty_Input}
	}
	p := Parser {
		data = data,
	}
	b, ok := peek(&p)
	if !ok {
		return nil, eof_error(&p)
	}
	if b != 'd' {
		return nil, invalid(&p, "expected dict")
	}
	p.off += 1

	found := false
	for {
		c, cok := peek(&p)
		if !cok {
			return nil, eof_error(&p)
		}
		if c == 'e' {
			p.off += 1
			if !found {
				return nil, Error{kind = .Invalid, offset = p.off, message = "missing key"}
			}
			return raw, {}
		}
		name: string
		name, err = parse_string_view(&p)
		if err.kind != .None {
			return nil, err
		}
		value_start := p.off
		err = skip_value(&p)
		if err.kind != .None {
			return nil, err
		}
		if name == key {
			raw = data[value_start:p.off]
			found = true
		}
	}
}

@(private)
parse_int :: proc(p: ^Parser) -> (value: Value, err: Error) {
	b, ok := peek(p)
	if !ok {
		return nil, eof_error(p)
	}
	if b != 'i' {
		return nil, invalid(p, "expected integer")
	}
	p.off += 1

	neg := false
	if sign, sok := peek(p); sok && sign == '-' {
		neg = true
		p.off += 1
	}

	if at_end(p) {
		return nil, eof_error(p)
	}

	first := p.data[p.off]
	if first < '0' || first > '9' {
		return nil, invalid(p, "integer has no digits")
	}

	n: i64
	digits := 0
	for !at_end(p) {
		c := p.data[p.off]
		if c == 'e' {
			break
		}
		if c < '0' || c > '9' {
			return nil, invalid(p, "invalid integer digit")
		}
		if digits == 0 && c == '0' {
			p.off += 1
			digits += 1
			if !at_end(p) && p.data[p.off] != 'e' {
				return nil, invalid(p, "leading zero in integer")
			}
			break
		}
		digit := i64(c - '0')
		if n > (max(i64) - digit) / 10 {
			return nil, Error{kind = .Overflow, offset = p.off}
		}
		n = n * 10 + digit
		digits += 1
		p.off += 1
	}

	if digits == 0 {
		return nil, invalid(p, "integer has no digits")
	}
	if at_end(p) || p.data[p.off] != 'e' {
		return nil, eof_error(p)
	}
	p.off += 1

	if neg {
		if n == 0 {
			return nil, invalid(p, "negative zero")
		}
		n = -n
	}
	return n, {}
}

@(private)
parse_string :: proc(p: ^Parser) -> (s: string, err: Error) {
	view: string
	view, err = parse_string_view(p)
	if err.kind != .None {
		return "", err
	}
	return strings.clone(view, p.allocator), {}
}

@(private)
parse_string_view :: proc(p: ^Parser) -> (s: string, err: Error) {
	if at_end(p) {
		return "", eof_error(p)
	}
	first := p.data[p.off]
	if first < '0' || first > '9' {
		return "", invalid(p, "expected string length")
	}

	n: int
	digits := 0
	for !at_end(p) {
		c := p.data[p.off]
		if c == ':' {
			break
		}
		if c < '0' || c > '9' {
			return "", invalid(p, "invalid string length")
		}
		if digits == 0 && c == '0' {
			p.off += 1
			digits += 1
			if !at_end(p) && p.data[p.off] != ':' {
				return "", invalid(p, "leading zero in string length")
			}
			break
		}
		n = n * 10 + int(c - '0')
		digits += 1
		p.off += 1
	}

	if digits == 0 || at_end(p) || p.data[p.off] != ':' {
		return "", eof_error(p)
	}
	p.off += 1

	if p.off + n > len(p.data) {
		return "", eof_error(p)
	}
	s = string(p.data[p.off:p.off + n])
	p.off += n
	return s, {}
}

@(private)
skip_string :: proc(p: ^Parser) -> Error {
	_, err := parse_string_view(p)
	return err
}

@(private)
parse_list :: proc(p: ^Parser) -> (value: Value, err: Error) {
	b, ok := peek(p)
	if !ok {
		return nil, eof_error(p)
	}
	if b != 'l' {
		return nil, invalid(p, "expected list")
	}
	p.off += 1

	list := make(List, p.allocator)
	defer if err.kind != .None {
		tmp := Value(list)
		destroy(&tmp, p.allocator)
	}

	for {
		c, cok := peek(p)
		if !cok {
			err = eof_error(p)
			return nil, err
		}
		if c == 'e' {
			p.off += 1
			return list, {}
		}
		item: Value
		item, err = parse_value(p)
		if err.kind != .None {
			return nil, err
		}
		append(&list, item)
	}
}

@(private)
parse_dict :: proc(p: ^Parser) -> (value: Value, err: Error) {
	b, ok := peek(p)
	if !ok {
		return nil, eof_error(p)
	}
	if b != 'd' {
		return nil, invalid(p, "expected dict")
	}
	p.off += 1

	dict := make(Dict, p.allocator)
	defer if err.kind != .None {
		tmp := Value(dict)
		destroy(&tmp, p.allocator)
	}

	for {
		c, cok := peek(p)
		if !cok {
			err = eof_error(p)
			return nil, err
		}
		if c == 'e' {
			p.off += 1
			return dict, {}
		}
		key: string
		key, err = parse_string(p)
		if err.kind != .None {
			return nil, err
		}
		item: Value
		item, err = parse_value(p)
		if err.kind != .None {
			delete(key, p.allocator)
			return nil, err
		}
		if old, exists := dict[key]; exists {
			old := old
			destroy(&old, p.allocator)
			dict[key] = item
			delete(key, p.allocator)
		} else {
			dict[key] = item
		}
	}
}
