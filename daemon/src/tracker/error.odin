package tracker

Error_Kind :: enum {
	None,
	Not_Implemented,
	Init_Failed,
	Request_Failed,
	Bad_Status,
	Invalid_Response,
}

Error :: struct {
	kind:    Error_Kind,
	status:  int,
	message: string,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Not_Implemented:
		return "tracker: not implemented"
	case .Init_Failed:
		return "tracker: curl init failed"
	case .Request_Failed:
		return err.message if err.message != "" else "tracker: request failed"
	case .Bad_Status:
		return "tracker: unexpected HTTP status"
	case .Invalid_Response:
		return "tracker: invalid announce response"
	}
	return "tracker: unknown error"
}
