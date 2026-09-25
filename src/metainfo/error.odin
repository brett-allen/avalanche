package metainfo

Error_Kind :: enum {
	None,
	Not_Implemented,
	Empty_Input,
	Invalid,
	Unsupported,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Not_Implemented:
		return "metainfo: not implemented"
	case .Empty_Input:
		return "metainfo: empty input"
	case .Invalid:
		return err.message if err.message != "" else "metainfo: invalid"
	case .Unsupported:
		return err.message if err.message != "" else "metainfo: unsupported"
	}
	return "metainfo: unknown error"
}
