package main

import "avalanche:bencode"
import "avalanche:metainfo"
import "avalanche:peer"
import "avalanche:session"
import "avalanche:storage"
import "avalanche:tracker"
import "core:crypto/hash"
import "core:fmt"
import "core:net"

HEX_HASH :: "6153e05ff068a25eeea1d4ea68a9637bdfd30ee8"
MAGNET :: "magnet:?xt=urn:btih:6153E05FF068A25EEEA1D4EA68A9637BDFD30EE8&dn=The.Miracle.Worker.1962.BluRay.1080p.DTS-HD.MA.2.0.HEVC-DDR[EtHD]&tr=udp://tracker.coppersurfer.tk:6969/announce&tr=udp://exodus.desync.com:6969/announce&tr=udp://open.demonii.si:1337/announce&tr=udp://tracker.pirateparty.gr:6969/announce&tr=udp://tracker.torrent.eu.org:451&tr=udp://tracker.tiny-vps.com:6969/announce&tr=udp://explodie.org:6969/announce&tr=udp://tracker.opentrackr.org:1337/announce&tr=udp://ipv4.tracker.harry.lu:80/announce&tr=udp://tracker.zer0day.to:1337/announce&tr=udp://tracker.leechers-paradise.org:6969/announce&tr=udp://coppersurfer.tk:6969/announce"
FIXTURE_MAGNET :: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Test%20File&tr=https%3A%2F%2Ftracker.example%2Fannounce&tr=udp://tracker.example:80&xl=1234&xs=https://example.com/file.torrent"

main :: proc() {
	client := session.client_make()
	defer session.destroy(&client)

	fmt.printfln("peer-id prefix %s", session.PEER_ID_PREFIX)
	fmt.printfln("listen port %d", int(client.listen_port))
	fmt.printfln("libcurl %s", tracker.curl_version())

	_, empty_err := bencode.parse(nil)
	assert(empty_err.kind == .Empty_Input)

	value, perr := bencode.parse(transmute([]byte)string("d3:fooi1e3:bari-2e4:spaml1:a1:bee"))
	assert(perr.kind == .None)
	dict, dict_ok := bencode.as_dict(value)
	assert(dict_ok)
	n, n_ok := bencode.dict_i64(dict, "foo")
	assert(n_ok && n == 1)
	n, n_ok = bencode.dict_i64(dict, "bar")
	assert(n_ok && n == -2)
	list, list_ok := bencode.as_list(bencode.dict_get(dict, "spam") or_else nil)
	assert(list_ok && len(list) == 2)
	bencode.destroy(&value)

	_, terr := metainfo.parse_torrent(nil)
	assert(terr.kind == .Empty_Input)

	torrent_src := "d8:announce26:http://tracker.example/ann4:infod6:lengthi4e4:name9:hello.txt12:piece lengthi16384e6:pieces20:01234567890123456789ee"
	torrent, tparse := metainfo.parse_torrent(transmute([]byte)torrent_src)
	assert(tparse.kind == .None)
	assert(torrent.info.name == "hello.txt")
	assert(metainfo.total_length(torrent.info) == 4)
	assert(metainfo.piece_count(torrent.info) == 1)
	assert(torrent.announce == "http://tracker.example/ann")
	metainfo.destroy(&torrent)

	assert(metainfo.is_magnet(MAGNET))
	assert(metainfo.is_magnet("MAGNET:?xt=urn:btih:0"))
	assert(!metainfo.is_magnet("./ubuntu.torrent"))

	magnet, merr := metainfo.parse_magnet(MAGNET)
	assert(merr.kind == .None)
	assert(magnet.display == "The.Miracle.Worker.1962.BluRay.1080p.DTS-HD.MA.2.0.HEVC-DDR[EtHD]")
	assert(len(magnet.trackers) == 12)
	assert(magnet.trackers[0] == "udp://tracker.coppersurfer.tk:6969/announce")
	assert(magnet.trackers[7] == "udp://tracker.opentrackr.org:1337/announce")
	hex := metainfo.info_hash_hex(magnet.info_hash)
	assert(hex == HEX_HASH)
	delete(hex)
	metainfo.magnet_destroy(&magnet)

	fixture, ferr := metainfo.parse_magnet(FIXTURE_MAGNET)
	assert(ferr.kind == .None)
	assert(fixture.display == "Test File")
	assert(fixture.exact_length == 1234)
	assert(len(fixture.trackers) == 2)
	assert(fixture.trackers[0] == "https://tracker.example/announce")
	assert(fixture.trackers[1] == "udp://tracker.example:80")
	assert(len(fixture.sources) == 1)
	assert(fixture.sources[0] == "https://example.com/file.torrent")
	metainfo.magnet_destroy(&fixture)

	zero_magnet, zerr := metainfo.parse_magnet(
		"magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	)
	assert(zerr.kind == .None)
	for b in zero_magnet.info_hash {
		assert(b == 0)
	}
	metainfo.magnet_destroy(&zero_magnet)

	body := [?]byte {
		'd',
		'8',
		':',
		'i',
		'n',
		't',
		'e',
		'r',
		'v',
		'a',
		'l',
		'i',
		'1',
		'8',
		'0',
		'0',
		'e',
		'5',
		':',
		'p',
		'e',
		'e',
		'r',
		's',
		'6',
		':',
		1,
		2,
		3,
		4,
		0x1a,
		0xe1,
		'e',
	}
	res, aerr := tracker.parse_announce_body(body[:])
	assert(aerr.kind == .None)
	assert(res.interval == 1800)
	assert(len(res.peers) == 1)
	ip, ip_ok := res.peers[0].endpoint.address.(net.IP4_Address)
	assert(ip_ok && ip == net.IP4_Address{1, 2, 3, 4})
	assert(res.peers[0].endpoint.port == 6881)
	tracker.announce_destroy(&res)

	assert(tracker.is_udp_tracker("udp://tracker.example:80"))
	assert(tracker.is_http_tracker("https://tracker.example/announce"))
	host, host_ok := tracker.parse_udp_tracker_host("udp://tracker.opentrackr.org:1337/announce")
	assert(host_ok && host == "tracker.opentrackr.org:1337")
	host, host_ok = tracker.parse_udp_tracker_host("udp://tracker.torrent.eu.org:451")
	assert(host_ok && host == "tracker.torrent.eu.org:451")

	connect := [16]byte {
		0, 0, 0, 0,
		0x11, 0x22, 0x33, 0x44,
		0, 0, 0, 0, 0, 0, 0, 7,
	}
	cid, cerr := tracker.parse_udp_connect_response(connect[:], 0x11223344)
	assert(cerr.kind == .None && cid == 7)

	announce_pkt := [26]byte {
		0, 0, 0, 1,
		0x11, 0x22, 0x33, 0x44,
		0, 0, 0x07, 0x08,
		0, 0, 0, 2,
		0, 0, 0, 5,
		1, 2, 3, 4, 0x1a, 0xe1,
	}
	ares, aparse := tracker.parse_udp_announce_response(announce_pkt[:], 0x11223344)
	assert(aparse.kind == .None)
	assert(ares.interval == 1800)
	assert(ares.incomplete == 2)
	assert(ares.complete == 5)
	assert(len(ares.peers) == 1)
	assert(ares.peers[0].endpoint.port == 6881)
	tracker.announce_destroy(&ares)

	assert(peer.PROTOCOL == "BitTorrent protocol")
	local := peer.make_handshake(
		{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20},
		{'-', 'A', 'V', '0', '0', '0', '1', '-', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
	)
	assert(peer.has_extension(local))
	wire, herr := peer.encode_handshake(local)
	assert(herr.kind == .None && len(wire) == peer.HANDSHAKE_SIZE)
	assert(wire[0] == 19)
	assert(string(wire[1:20]) == peer.PROTOCOL)
	remote, derr := peer.decode_handshake(wire)
	assert(derr.kind == .None)
	assert(remote.info_hash == local.info_hash)
	assert(remote.peer_id == local.peer_id)
	assert(peer.has_extension(remote))
	delete(wire)

	src := transmute([]byte)string("d3:bari-2e3:fooi1ee")
	parsed, perr2 := bencode.parse(src)
	assert(perr2.kind == .None)
	round, rerr := bencode.encode(parsed)
	assert(rerr.kind == .None)
	assert(string(round) == "d3:bari-2e3:fooi1ee")
	bencode.destroy(&parsed)
	delete(round)

	prefix, consumed, pferr := bencode.parse_prefix(transmute([]byte)string("i42eextra"))
	assert(pferr.kind == .None && consumed == 4)
	n42, n42_ok := bencode.as_i64(prefix)
	assert(n42_ok && n42 == 42)
	bencode.destroy(&prefix)

	info_src := transmute([]byte)torrent_src
	raw_info, raw_err := bencode.raw_top_value(info_src, "info")
	assert(raw_err.kind == .None)
	info, info_hash, ierr := metainfo.parse_info(raw_info)
	assert(ierr.kind == .None)
	assert(info.name == "hello.txt")
	assert(metainfo.total_length(info) == 4)
	torrent2, t2err := metainfo.parse_torrent(info_src)
	assert(t2err.kind == .None && torrent2.info_hash == info_hash)
	metainfo.destroy(&torrent2)
	metainfo.info_destroy(&info)

	req, req_err := peer.encode_metadata_request(3, 0)
	assert(req_err.kind == .None)
	assert(req[0] == 3)
	assert(string(req[1:]) == "d8:msg_typei0e5:piecei0ee")
	delete(req)

	header := "d8:msg_typei1e5:piecei0e10:total_sizei4ee"
	payload := make([]byte, 1 + len(header) + 4)
	payload[0] = 1
	copy(payload[1:], header)
	copy(payload[1 + len(header):], transmute([]byte)string("abcd"))
	kind, piece, total, data, meta_err := peer.decode_metadata_message(payload)
	assert(meta_err.kind == .None)
	assert(kind == .Data && piece == 0 && total == 4)
	assert(string(data) == "abcd")
	delete(payload)

	ext_payload, xerr := peer.encode_extended_handshake(6881)
	assert(xerr.kind == .None)
	assert(ext_payload[0] == peer.EXT_HANDSHAKE_ID)
	ext, dxerr := peer.decode_extended_handshake(ext_payload)
	assert(dxerr.kind == .None)
	meta_id, meta_ok := peer.extension_id(ext, peer.UT_METADATA)
	assert(meta_ok && meta_id == peer.UT_METADATA_LOCAL_ID)
	assert(ext.client == peer.CLIENT_VERSION)
	assert(ext.port == 6881)
	peer.extended_destroy(&ext)
	delete(ext_payload)

	keep, kerr := peer.encode_message(peer.Message{keep_alive = true})
	assert(kerr.kind == .None && len(keep) == 4)
	decoded_keep, kderr := peer.decode_message(keep)
	assert(kderr.kind == .None && decoded_keep.keep_alive)
	delete(keep)

	req_wire, rwerr := peer.encode_request(7, 16384, 16384)
	assert(rwerr.kind == .None && len(req_wire) == 17)
	assert(req_wire[4] == u8(peer.Message_Id.Request))
	delete(req_wire)

	bf := peer.bitfield_make(10)
	assert(!peer.bitfield_has(bf, 3))
	peer.bitfield_set(&bf, 3)
	assert(peer.bitfield_has(bf, 3))
	peer.bitfield_destroy(&bf)

	{
		payload := transmute([]byte)string("hello")
		sum: [20]u8
		hash.hash(.Insecure_SHA1, payload, sum[:])
		info := metainfo.Info{
			name         = "hello.txt",
			piece_length = 5,
			pieces       = sum[:],
			length       = 5,
		}
		assert(metainfo.verify_piece(info, 0, payload))
		assert(metainfo.piece_length_at(info, 0) == 5)
		store, serr := storage.open("build/storage_test", info)
		assert(serr.kind == .None)
		werr := storage.write_piece(&store, 0, payload)
		assert(werr.kind == .None)
		buf: [5]byte
		n, rerr := storage.read_piece(&store, 0, buf[:])
		assert(rerr.kind == .None && n == 5 && string(buf[:]) == "hello")
		storage.close(&store)
	}

	assert(storage.error_string(storage.Error{kind = .Open_Failed}) != "")

	{
		eng := session.engine_make()
		defer session.engine_destroy(eng)
		id1, e1 := session.engine_add_magnet(
			eng,
			"magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&dn=Engine+Test+One",
			"build/engine_test",
		)
		assert(e1.kind == .None && id1 != 0)
		id2, e2 := session.engine_add_magnet(
			eng,
			"magnet:?xt=urn:btih:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&dn=Engine+Test+Two",
			"build/engine_test",
		)
		assert(e2.kind == .None && id2 != 0 && id2 != id1)
		session.engine_wait_all(eng)
		list := session.engine_list(eng)
		assert(len(list) == 2)
		for &st in list {
			assert(st.state == .Failed || st.state == .Stopped || st.state == .Complete)
			session.status_destroy(&st)
		}
		delete(list)
	}

	fmt.println("scaffold ok")
}
