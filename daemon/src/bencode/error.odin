package bencode

Error_Kind :: enum {
	None,
	Not_Implemented,
	Empty_Input,
	Invalid,
	Unexpected_Eof,
	Overflow,
}

Error :: struct {
	kind:    Error_Kind,
	offset:  int,
	message: string,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Not_Implemented:
		return "bencode: not implemented"
	case .Empty_Input:
		return "bencode: empty input"
	case .Invalid:
		return err.message if err.message != "" else "bencode: invalid data"
	case .Unexpected_Eof:
		return "bencode: unexpected end of input"
	case .Overflow:
		return "bencode: integer overflow"
	}
	return "bencode: unknown error"
}
