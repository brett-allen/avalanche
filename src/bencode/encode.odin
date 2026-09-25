package bencode

import "core:fmt"
import "core:slice"
import "core:strings"

encode :: proc(value: Value, allocator := context.allocator) -> (data: []byte, err: Error) {
	b := strings.builder_make(allocator)
	err = write_value(&b, value)
	if err.kind != .None {
		strings.builder_destroy(&b)
		return nil, err
	}
	return transmute([]byte)strings.to_string(b), {}
}

@(private)
write_value :: proc(b: ^strings.Builder, value: Value) -> Error {
	switch v in value {
	case i64:
		strings.write_byte(b, 'i')
		fmt.sbprintf(b, "%d", v)
		strings.write_byte(b, 'e')
	case string:
		fmt.sbprintf(b, "%d:", len(v))
		strings.write_string(b, v)
	case List:
		strings.write_byte(b, 'l')
		for item in v {
			if err := write_value(b, item); err.kind != .None {
				return err
			}
		}
		strings.write_byte(b, 'e')
	case Dict:
		keys := make([dynamic]string, context.temp_allocator)
		for key in v {
			append(&keys, key)
		}
		slice.sort(keys[:])
		strings.write_byte(b, 'd')
		for key in keys {
			fmt.sbprintf(b, "%d:", len(key))
			strings.write_string(b, key)
			if err := write_value(b, v[key]); err.kind != .None {
				return err
			}
		}
		strings.write_byte(b, 'e')
	case:
		return Error{kind = .Invalid, message = "cannot encode empty bencode value"}
	}
	return {}
}
