/*
	BitTorrent DHT (BEP 5) — Kademlia over UDP for trackerless peer discovery.
*/
package dht

import "core:crypto"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

K            :: 8
ALPHA        :: 3
NODE_ID_SIZE :: 20
COMPACT_NODE :: 26
COMPACT_PEER :: 6

RPC_TIMEOUT      :: 1 * time.Second
BOOTSTRAP_ROUNDS :: 8
LOOKUP_ROUNDS    :: 16

BOOTSTRAP_HOSTS :: [?]string{
	"router.bittorrent.com:6881",
	"dht.transmissionbt.com:6881",
	"router.utorrent.com:6881",
	"dht.libtorrent.org:25401",
}

Node_ID :: distinct [NODE_ID_SIZE]u8

Contact :: struct {
	id:       Node_ID,
	endpoint: net.Endpoint,
}

Error_Kind :: enum {
	None,
	Init_Failed,
	Timeout,
	Network,
	Protocol,
	Invalid,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None:
		return "ok"
	case .Init_Failed:
		return err.message if err.message != "" else "dht: init failed"
	case .Timeout:
		return err.message if err.message != "" else "dht: timeout"
	case .Network:
		return err.message if err.message != "" else "dht: network error"
	case .Protocol:
		return err.message if err.message != "" else "dht: protocol error"
	case .Invalid:
		return err.message if err.message != "" else "dht: invalid"
	}
	return "dht: unknown error"
}

@(private)
dht_fail :: proc(kind: Error_Kind, msg: string, allocator := context.allocator) -> Error {
	return Error{kind = kind, message = strings.clone(msg, allocator)}
}

Node :: struct {
	id:           Node_ID,
	sock:         net.UDP_Socket,
	port:         u16,
	table:        Routing_Table,
	mu:           sync.Mutex,
	tid:          u16,
	bootstrapped: bool,
	allocator:    mem.Allocator,
}

distance :: proc(a, b: Node_ID) -> Node_ID {
	out: Node_ID
	for i in 0 ..< NODE_ID_SIZE {
		out[i] = a[i] ~ b[i]
	}
	return out
}

// closer returns true if a is closer to target than b (XOR metric).
closer :: proc(a, b, target: Node_ID) -> bool {
	da := distance(a, target)
	db := distance(b, target)
	for i in 0 ..< NODE_ID_SIZE {
		if da[i] < db[i] {
			return true
		}
		if da[i] > db[i] {
			return false
		}
	}
	return false
}

id_from_bytes :: proc(data: []byte) -> (id: Node_ID, ok: bool) {
	if len(data) != NODE_ID_SIZE {
		return {}, false
	}
	copy(id[:], data)
	return id, true
}

id_bytes :: proc(id: Node_ID, allocator := context.allocator) -> string {
	id := id
	buf := make([]byte, NODE_ID_SIZE, allocator)
	copy(buf, id[:])
	return transmute(string)buf
}

random_id :: proc() -> (id: Node_ID) {
	crypto.rand_bytes(id[:])
	return
}

node_make :: proc(port: u16 = 6881, allocator := context.allocator) -> (node: ^Node, err: Error) {
	node = new(Node, allocator)
	node.id = random_id()
	node.port = port if port != 0 else 6881
	node.allocator = allocator
	routing_init(&node.table, node.id, allocator)

	sock, serr := net.make_unbound_udp_socket(.IP4)
	if serr != nil {
		free(node, allocator)
		return nil, dht_fail(.Init_Failed, "could not open DHT UDP socket", allocator)
	}
	bind_ep := net.Endpoint{address = net.IP4_Any, port = int(node.port)}
	if berr := net.bind(sock, bind_ep); berr != nil {
		bind_ep.port = 0
		if berr2 := net.bind(sock, bind_ep); berr2 != nil {
			net.close(sock)
			free(node, allocator)
			return nil, dht_fail(.Init_Failed, "could not bind DHT UDP socket", allocator)
		}
	}
	if local, lerr := net.bound_endpoint(sock); lerr == nil {
		node.port = u16(local.port)
	}
	node.sock = sock
	_ = net.set_option(sock, .Receive_Timeout, 250 * time.Millisecond)
	return node, {}
}

node_destroy :: proc(node: ^Node) {
	if node == nil {
		return
	}
	if node.sock != 0 {
		net.close(node.sock)
		node.sock = 0
	}
	routing_destroy(&node.table)
	free(node, node.allocator)
}

// bootstrap populates the routing table from well-known DHT routers.
bootstrap :: proc(node: ^Node, allocator := context.allocator) -> Error {
	if node == nil {
		return dht_fail(.Invalid, "nil dht node", allocator)
	}
	if node.bootstrapped && routing_count(&node.table) > 0 {
		return {}
	}

	for host in BOOTSTRAP_HOSTS {
		ep4, ep6, rerr := net.resolve(host)
		_ = rerr
		remote := ep4 if ep4.address != nil else ep6
		if remote.address == nil || remote.port == 0 {
			continue
		}
		_ = rpc_ping(node, remote, allocator)
		nodes, _ := rpc_find_node(node, remote, node.id, allocator)
		for n in nodes {
			routing_insert(&node.table, n)
		}
		delete(nodes, allocator)
	}

	_ = iterative_find_node(node, node.id, allocator)
	node.bootstrapped = routing_count(&node.table) > 0
	if !node.bootstrapped {
		return dht_fail(.Network, "DHT bootstrap found no nodes", allocator)
	}
	log.infof("dht: bootstrap ok nodes=%d udp/%d", routing_count(&node.table), int(node.port))
	return {}
}

// get_peers performs an iterative BEP 5 get_peers lookup for info_hash,
// then announce_peers so the swarm can dial us back.
get_peers :: proc(
	node: ^Node,
	info_hash: Node_ID,
	allocator := context.allocator,
) -> (
	peers: []net.Endpoint,
	err: Error,
) {
	if node == nil {
		return nil, dht_fail(.Invalid, "nil dht node", allocator)
	}
	if serr := bootstrap(node, allocator); serr.kind != .None {
		if routing_count(&node.table) == 0 {
			return nil, serr
		}
		if serr.message != "" {
			delete(serr.message, allocator)
		}
	}
	found, tokens, perr := iterative_get_peers(node, info_hash, allocator)
	if perr.kind != .None {
		return nil, perr
	}
	// Best-effort announce (no wait) so peers can dial us; don't stall the lookup.
	announced := 0
	for h in tokens {
		if announced < 8 {
			_ = rpc_announce_peer_noreply(node, h.endpoint, info_hash, h.token, node.port, allocator)
			announced += 1
		}
		delete(h.token, allocator)
	}
	delete(tokens, allocator)
	log.debugf("dht: announced to %d nodes, peers=%d", announced, len(found))
	return found, {}
}
