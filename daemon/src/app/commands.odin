package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"
import "avalanche:metainfo"
import "avalanche:peer"
import "avalanche:session"
import "avalanche:tracker"

MAX_HANDSHAKES :: 8

VERSION :: "0.1.0-dev"

run_version :: proc() {
	fmt.printfln("avalanche %s", VERSION)
	fmt.printfln("libcurl %s", tracker.curl_version())
	fmt.printfln("peer-id prefix %s", session.PEER_ID_PREFIX)
}

run_info :: proc(opt: Options, rt: Runtime) {
	if metainfo.is_magnet(opt.input) {
		run_info_magnet(opt, rt)
		return
	}

	data, read_err := os.read_entire_file(opt.input, context.allocator)
	if read_err != nil {
		fmt.eprintfln("%s cannot read %s", paint(.Err, "error:"), opt.input)
		os.exit(1)
	}
	defer delete(data)

	torrent, err := metainfo.parse_torrent(data)
	if err.kind != .None {
		fmt.eprintfln("%s %s", paint(.Err, "error:"), metainfo.error_string(err))
		os.exit(1)
	}
	defer metainfo.destroy(&torrent)
	print_torrent_summary(torrent, opt.verbose)
}

run_info_magnet :: proc(opt: Options, rt: Runtime) {
	magnet, err := metainfo.parse_magnet(opt.input)
	if err.kind != .None {
		fmt.eprintfln("%s %s", paint(.Err, "error:"), metainfo.error_string(err))
		os.exit(1)
	}
	defer metainfo.magnet_destroy(&magnet)

	print_magnet_summary(magnet, opt.verbose)

	client := session.client_make(rt.listen_port, rt.dht_enabled)
	defer session.destroy(&client)

	got_meta := false
	for source in magnet.sources {
		if !tracker.is_http_tracker(source) {
			continue
		}
		if opt.verbose {
			kv("source", source, .Muted)
		}
		resp, herr := tracker.http_get(source)
		if herr.kind != .None {
			if opt.verbose {
				fmt.eprintfln("%s %s", paint(.Err, "error:"), tracker.error_string(herr))
			}
			if herr.message != "" {
				delete(herr.message)
			}
			tracker.http_response_destroy(&resp)
			continue
		}
		torrent, terr := metainfo.parse_torrent(resp.body)
		tracker.http_response_destroy(&resp)
		if terr.kind != .None {
			if opt.verbose {
				fmt.eprintfln("%s %s", paint(.Err, "error:"), metainfo.error_string(terr))
			}
			continue
		}
		if torrent.info_hash != magnet.info_hash {
			metainfo.destroy(&torrent)
			if opt.verbose {
				fmt.eprintfln("%s fetched torrent infohash does not match magnet", paint(.Err, "error:"))
			}
			continue
		}
		fmt.println()
		print_torrent_summary(torrent, opt.verbose)
		metainfo.destroy(&torrent)
		got_meta = true
		break
	}

	if opt.no_announce {
		return
	}

	req := session.announce_request(client, magnet)
	peers: [dynamic]tracker.Peer_Addr
	defer delete(peers)

	ok_n := 0
	fail_n := 0
	skip_n := 0
	seeders: i64
	leechers: i64
	for url in magnet.trackers {
		if !tracker.is_udp_tracker(url) && !tracker.is_http_tracker(url) {
			skip_n += 1
			if opt.verbose {
				kv("announce", fmt.tprintf("%s (skipped)", url), .Muted)
			}
			continue
		}
		if opt.verbose {
			kv("announce", url, .Muted)
		}
		res, aerr := tracker.announce(url, req)
		if aerr.kind != .None {
			fail_n += 1
			if opt.verbose {
				if aerr.status != 0 {
					fmt.eprintfln("%s %s (%d)", paint(.Err, "error:"), tracker.error_string(aerr), aerr.status)
				} else {
					fmt.eprintfln("%s %s", paint(.Err, "error:"), tracker.error_string(aerr))
				}
				if aerr.message != "" {
					fmt.eprintfln("         %s", aerr.message)
					delete(aerr.message)
				}
			} else if aerr.message != "" {
				delete(aerr.message)
			}
			continue
		}
		ok_n += 1
		seeders += res.complete
		leechers += res.incomplete
		if opt.verbose {
			print_announce_verbose(res)
		}
		collect_peers(&peers, res.peers[:])
		tracker.announce_destroy(&res)
	}

	fmt.println()
	if len(magnet.trackers) == 0 {
		kv("announce", "no trackers", .Warn)
	} else {
		summary: string
		if skip_n > 0 {
			summary = fmt.tprintf("%d ok · %d failed · %d skipped · %d peers", ok_n, fail_n, skip_n, len(peers))
		} else {
			summary = fmt.tprintf("%d ok · %d failed · %d peers", ok_n, fail_n, len(peers))
		}
		kv("announce", summary, .Ok if ok_n > 0 else .Warn)
		if ok_n > 0 && (seeders > 0 || leechers > 0) {
			kv("swarm", fmt.tprintf("%d seeders · %d leechers", seeders, leechers), .Muted)
		}
	}

	if !got_meta {
		shake_hands(client, magnet.info_hash, peers[:], opt.verbose)
	}
}

run_download :: proc(opt: Options, rt: Runtime) {
	inputs := gather_download_inputs(opt)
	if len(inputs) == 0 {
		fmt.eprintfln("%s download requires a magnet URI or .torrent path", paint(.Err, "error:"))
		os.exit(1)
	}

	out := rt.download_dir
	eng := session.engine_make(rt.listen_port, rt.dht_enabled)
	defer session.engine_destroy(eng)

	ids: [dynamic]session.Torrent_ID
	defer delete(ids)

	for input in inputs {
		kv("add", input, .Muted)
		id: session.Torrent_ID
		err: session.Error
		if metainfo.is_magnet(input) {
			id, err = session.engine_add_magnet(eng, input, out)
		} else {
			id, err = session.engine_add_torrent_file(eng, input, out)
		}
		if err.kind != .None {
			fmt.eprintfln("%s %s", paint(.Err, "error:"), session.error_string(err))
			if err.message != "" {
				delete(err.message)
			}
			os.exit(1)
		}
		append(&ids, id)
	}

	kv("output", out)
	kv("torrents", fmt.tprintf("%d (thread each)", len(ids)))
	fmt.println()
	section("downloading…")

	lines := 0
	for {
		statuses := session.engine_list(eng)
		cursor_up(lines)
		lines = render_engine_status(statuses)
		os.flush(os.stdout)

		all_done := true
		for &st in statuses {
			if st.state != .Complete && st.state != .Failed && st.state != .Stopped {
				all_done = false
			}
			session.status_destroy(&st)
		}
		delete(statuses)

		if all_done {
			break
		}
		time.sleep(200 * time.Millisecond)
	}

	fmt.println()
	final := session.engine_list(eng)
	defer {
		for &st in final {
			session.status_destroy(&st)
		}
		delete(final)
	}
	fail_n := 0
	for st in final {
		style: Style = .Ok
		detail := fmt.tprintf(
			"%s · %d/%d pieces · %s",
			session.torrent_state_string(st.state),
			st.pieces_done,
			st.pieces_total,
			human_bytes(st.bytes_done),
		)
		if st.state == .Failed {
			style = .Err
			fail_n += 1
			if st.error != "" {
				detail = fmt.tprintf("%s · %s", detail, st.error)
			}
		} else if st.state == .Stopped {
			style = .Warn
		}
		kv(st.name if st.name != "" else fmt.tprintf("#%d", int(st.id)), detail, style)
	}
	if fail_n > 0 {
		os.exit(1)
	}
}

gather_download_inputs :: proc(opt: Options) -> []string {
	out: [dynamic]string
	seen: map[string]bool
	defer delete(seen)

	add :: proc(dst: ^[dynamic]string, seen: ^map[string]bool, s: string) {
		if s == "" || (s in seen) {
			return
		}
		if metainfo.is_magnet(s) || is_torrent_path(s) {
			seen[s] = true
			append(dst, s)
		}
	}

	add(&out, &seen, opt.input)
	for arg in os.args[1:] {
		if len(arg) > 0 && arg[0] == '-' {
			continue
		}
		if arg == "download" || arg == "info" || arg == "version" ||
		   arg == "Download" || arg == "Info" || arg == "Version" {
			continue
		}
		add(&out, &seen, arg)
	}
	return out[:]
}

is_torrent_path :: proc(s: string) -> bool {
	n := len(s)
	if n < 8 {
		return false
	}
	ext := s[n - 8:]
	return ext == ".torrent" || ext == ".TORRENT"
}

render_engine_status :: proc(statuses: []session.Torrent_Status) -> int {
	lines := 0
	for st in statuses {
		clear_line()
		fmt.printfln("%s", paint(.Value, st.name if st.name != "" else fmt.tprintf("torrent #%d", int(st.id))))
		lines += 1

		status_line("state", session.torrent_state_string(st.state), .Muted)
		lines += 1

		prog := fmt.tprintf(
			"%d/%d pieces · %s / %s (%d%%)",
			st.pieces_done,
			st.pieces_total,
			human_bytes(st.bytes_done),
			human_bytes(st.bytes_total),
			pct(st.bytes_done, st.bytes_total),
		)
		status_line("progress", prog, .Ok)
		lines += 1

		peers := fmt.tprintf(
			"%d tried · %d live · %d failed · %d active",
			st.peers_tried,
			st.peers_live,
			st.peers_failed,
			st.peers_active,
		)
		status_line("peers", peers, .Muted)
		lines += 1

		if st.error != "" {
			status_line("error", st.error, .Err)
			lines += 1
		}
		clear_line()
		fmt.println()
		lines += 1
	}
	return lines
}

status_line :: proc(label, value: string, style: Style = .Value) {
	clear_line()
	fmt.printfln("%s%-10s%s %s", style_code(.Label), label, reset_code(), paint(style, value))
}

print_magnet_summary :: proc(magnet: metainfo.Magnet, verbose: bool) {
	hash := metainfo.info_hash_hex(magnet.info_hash)
	defer delete(hash)

	if magnet.display != "" {
		fmt.printfln("%s", paint(.Value, magnet.display))
	} else {
		fmt.printfln("%s", paint(.Value, short_hash(hash)))
	}
	kv("infohash", hash if verbose else short_hash(hash))
	if magnet.exact_length > 0 {
		kv("length", human_bytes(magnet.exact_length))
	}
	kv("trackers", fmt.tprintf("%d", len(magnet.trackers)))
	if len(magnet.webseeds) > 0 {
		kv("webseeds", fmt.tprintf("%d", len(magnet.webseeds)))
	}
	if len(magnet.sources) > 0 {
		kv("sources", fmt.tprintf("%d", len(magnet.sources)))
	}

	if verbose {
		for url in magnet.trackers {
			kv("tracker", url, .Muted)
		}
		for url in magnet.webseeds {
			kv("webseed", url, .Muted)
		}
		for url in magnet.sources {
			kv("source", url, .Muted)
		}
	}
}

print_torrent_summary :: proc(torrent: metainfo.Torrent, verbose: bool) {
	print_info_summary(torrent.info, torrent.info_hash, verbose)
	if verbose && torrent.announce != "" {
		kv("announce", torrent.announce, .Muted)
	}
}

print_info_summary :: proc(info: metainfo.Info, info_hash: metainfo.Info_Hash, verbose: bool) {
	hash := metainfo.info_hash_hex(info_hash)
	defer delete(hash)

	if info.name != "" {
		fmt.printfln("%s", paint(.Value, info.name))
	}
	kv("infohash", hash if verbose else short_hash(hash))
	kv("length", human_bytes(metainfo.total_length(info)))
	kv("pieces", fmt.tprintf("%d × %s", metainfo.piece_count(info), human_bytes(info.piece_length)))
	if info.private {
		kv("private", "yes", .Warn)
	}
	if len(info.files) > 0 {
		kv("files", fmt.tprintf("%d", len(info.files)))
		limit := len(info.files) if verbose else min(5, len(info.files))
		for i in 0 ..< limit {
			file := info.files[i]
			path := join_path(file.path)
			kv("file", fmt.tprintf("%s  %s", human_bytes(file.length), path), .Muted)
		}
		if !verbose && len(info.files) > limit {
			kv("file", fmt.tprintf("… %d more (use --verbose)", len(info.files) - limit), .Muted)
		}
	}
}

join_path :: proc(parts: []string) -> string {
	if len(parts) == 0 {
		return ""
	}
	out := parts[0]
	for i in 1 ..< len(parts) {
		out = fmt.tprintf("%s/%s", out, parts[i])
	}
	return out
}

collect_peers :: proc(dst: ^[dynamic]tracker.Peer_Addr, src: []tracker.Peer_Addr) {
	for peer in src {
		exists := false
		for have in dst {
			if have.endpoint == peer.endpoint {
				exists = true
				break
			}
		}
		if !exists {
			append(dst, peer)
		}
	}
}

shake_hands :: proc(client: session.Client, info_hash: metainfo.Info_Hash, peers: []tracker.Peer_Addr, verbose: bool) {
	if len(peers) == 0 {
		kv("peers", "none to contact", .Warn)
		return
	}

	local := peer.make_handshake(transmute([20]u8)info_hash, client.peer_id)
	tried := 0
	ok_count := 0
	meta_ok := false
	shown_peer := false

	for p in peers {
		if tried >= MAX_HANDSHAKES {
			break
		}
		tried += 1
		ep := net.endpoint_to_string(p.endpoint, context.temp_allocator)
		if verbose {
			kv("handshake", ep, .Muted)
		}
		ex, err := peer.exchange_peer(p.endpoint, local, client.listen_port)
		if err.kind != .None {
			if verbose {
				fmt.eprintfln("%s %s", paint(.Err, "error:"), peer.error_string(err))
			}
			if err.message != "" {
				delete(err.message)
			}
			continue
		}
		ok_count += 1
		{
			defer peer.exchange_destroy(&ex)
			label := peer.peer_id_label(ex.remote.peer_id)
			defer delete(label)
			client_name := ex.extended.client if ex.got_extended && ex.extended.client != "" else label

			if verbose {
				kv("peer-id", label)
				if peer.has_extension(ex.remote) {
					kv("extension", "yes", .Ok)
				}
				if ex.got_extended {
					print_extended_verbose(ex.extended)
				} else if peer.has_extension(ex.remote) {
					kv("extension", "no handshake", .Warn)
				}
			}

			if ex.got_metadata {
				info, ih, ierr := metainfo.parse_info(ex.metadata)
				if ierr.kind != .None {
					if verbose {
						fmt.eprintfln("%s %s", paint(.Err, "error:"), metainfo.error_string(ierr))
					}
				} else if ih != info_hash {
					metainfo.info_destroy(&info)
					if verbose {
						fmt.eprintfln("%s fetched infohash does not match magnet", paint(.Err, "error:"))
					}
				} else {
					meta_ok = true
					fmt.println()
					kv("peer", fmt.tprintf("%s  %s", client_name, ep), .Ok)
					kv("metadata", human_bytes(i64(len(ex.metadata))), .Ok)
					fmt.println()
					print_info_summary(info, ih, verbose)
					metainfo.info_destroy(&info)
					break
				}
			} else if verbose && ex.metadata_err.kind != .None {
				fmt.eprintfln("%s %s", paint(.Err, "error:"), peer.error_string(ex.metadata_err))
			} else if !verbose && !shown_peer {
				kv("peer", fmt.tprintf("%s  %s", client_name, ep), .Ok)
				shown_peer = true
			}
		}
	}

	fmt.println()
	status: Style = .Ok if ok_count > 0 else .Warn
	if meta_ok {
		kv("handshake", fmt.tprintf("%d/%d ok · metadata fetched", ok_count, tried), status)
	} else {
		kv("handshake", fmt.tprintf("%d/%d ok", ok_count, tried), status)
	}
}

print_extended_verbose :: proc(ext: peer.Extended_Handshake) {
	if ext.client != "" {
		kv("client", ext.client)
	}
	if ext.metadata_size > 0 {
		kv("metadata", human_bytes(ext.metadata_size))
	}
	if ext.port > 0 {
		kv("listen", fmt.tprintf("%d", ext.port), .Muted)
	}
	for name, id in ext.messages {
		kv("ext", fmt.tprintf("%s=%d", name, int(id)), .Muted)
	}
}

print_announce_verbose :: proc(res: tracker.Announce_Response) {
	kv(
		"result",
		fmt.tprintf(
			"interval %ds · seeders %d · leechers %d · peers %d",
			res.interval,
			res.complete,
			res.incomplete,
			len(res.peers),
		),
		.Muted,
	)
	for peer in res.peers {
		ep := net.endpoint_to_string(peer.endpoint, context.temp_allocator)
		kv("peer", ep, .Muted)
	}
}
