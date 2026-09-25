/*
	Bencode (BEP 3) values used by .torrent files, tracker responses, and DHT.
*/
package bencode

List :: [dynamic]Value
Dict :: map[string]Value

Value :: union {
	i64,
	string,
	List,
	Dict,
}

parse :: proc(data: []byte, allocator := context.allocator) -> (value: Value, err: Error) {
	value, _, err = parse_prefix(data, allocator)
	return
}

// parse_prefix parses one value and reports how many input bytes it consumed.
parse_prefix :: proc(data: []byte, allocator := context.allocator) -> (value: Value, consumed: int, err: Error) {
	if len(data) == 0 {
		return nil, 0, Error{kind = .Empty_Input}
	}
	p := Parser {
		data      = data,
		allocator = allocator,
	}
	value, err = parse_value(&p)
	if err.kind != .None {
		destroy(&value, allocator)
		return nil, 0, err
	}
	return value, p.off, {}
}


as_i64 :: proc(value: Value) -> (n: i64, ok: bool) {
	n, ok = value.(i64)
	return
}

as_string :: proc(value: Value) -> (s: string, ok: bool) {
	s, ok = value.(string)
	return
}

as_list :: proc(value: Value) -> (list: List, ok: bool) {
	list, ok = value.(List)
	return
}

as_dict :: proc(value: Value) -> (dict: Dict, ok: bool) {
	dict, ok = value.(Dict)
	return
}

dict_get :: proc(dict: Dict, key: string) -> (value: Value, ok: bool) {
	value, ok = dict[key]
	return
}

dict_i64 :: proc(dict: Dict, key: string) -> (n: i64, ok: bool) {
	return as_i64(dict_get(dict, key) or_return)
}

dict_string :: proc(dict: Dict, key: string) -> (s: string, ok: bool) {
	return as_string(dict_get(dict, key) or_return)
}

destroy :: proc(value: ^Value, allocator := context.allocator) {
	if value == nil {
		return
	}
	switch v in value {
	case i64:
	case string:
		delete(v, allocator)
	case List:
		for &item in v {
			destroy(&item, allocator)
		}
		delete(v)
	case Dict:
		for key, &item in v {
			delete(key, allocator)
			destroy(&item, allocator)
		}
		delete(v)
	}
	value^ = nil
}
