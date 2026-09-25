/*
	Peer wire protocol (BEP 3). Handshake plus the fixed message set.
	Connections will sit on core:nbio.
*/
package peer

PROTOCOL :: "BitTorrent protocol"

Message_Id :: enum u8 {
	Choke          = 0,
	Unchoke        = 1,
	Interested     = 2,
	Not_Interested = 3,
	Have           = 4,
	Bitfield       = 5,
	Request        = 6,
	Piece          = 7,
	Cancel         = 8,
	Port           = 9,
	Extended       = 20,
}

Handshake :: struct {
	reserved:  [8]u8,
	info_hash: [20]u8,
	peer_id:   [20]u8,
}

Error_Kind :: enum {
	None,
	Not_Implemented,
	Invalid,
	Protocol,
	Connect,
	Timeout,
	IO,
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
		return "peer: not implemented"
	case .Invalid:
		return err.message if err.message != "" else "peer: invalid message"
	case .Protocol:
		return err.message if err.message != "" else "peer: protocol error"
	case .Connect:
		return err.message if err.message != "" else "peer: connect failed"
	case .Timeout:
		return err.message if err.message != "" else "peer: timed out"
	case .IO:
		return err.message if err.message != "" else "peer: i/o error"
	}
	return "peer: unknown error"
}
