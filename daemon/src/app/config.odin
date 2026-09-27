package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "avalanche:api"
import "avalanche:session"

DEFAULT_CONFIG_PATH :: "avalanche.json"

// File_Config is the on-disk JSON shape (core:encoding/json struct tags).
File_Config :: struct {
	listen_port:  u16    `json:"listen_port"`,
	download_dir: string `json:"download_dir"`,
	api_host:     string `json:"api_host"`,
	api_port:     u16    `json:"api_port"`,
	dht_enabled:  bool   `json:"dht_enabled"`,
}

// Runtime holds resolved settings after defaults → file → CLI merge.
Runtime :: struct {
	listen_port:  u16,
	download_dir: string,
	api_host:     string,
	api_addr:     net.Address,
	api_port:     u16,
	dht_enabled:  bool,
	config_path:  string, // empty if no file was loaded
	verbose:      bool,
}

file_config_defaults :: proc() -> File_Config {
	return File_Config{
		listen_port  = session.DEFAULT_PORT,
		download_dir = "downloads",
		api_host     = "127.0.0.1",
		api_port     = api.DEFAULT_API_PORT,
		dht_enabled  = true,
	}
}

load_file_config :: proc(path: string, allocator := context.allocator) -> (cfg: File_Config, loaded: bool, missing: bool, err_msg: string) {
	cfg = file_config_defaults()
	if path == "" {
		return cfg, false, true, ""
	}
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return cfg, false, true, ""
	}
	defer delete(data, allocator)

	if jerr := json.unmarshal(data, &cfg, allocator = allocator); jerr != nil {
		return file_config_defaults(), false, false, fmt.tprintf("invalid config %s: %v", path, jerr)
	}
	return cfg, true, false, ""
}

resolve_api_host :: proc(host: string) -> (net.Address, bool) {
	h := strings.trim_space(host)
	if h == "" || h == "localhost" || h == "127.0.0.1" {
		return net.IP4_Loopback, true
	}
	if h == "0.0.0.0" || h == "*" {
		return net.IP4_Any, true
	}
	addr := net.parse_address(h)
	if addr == nil {
		return nil, false
	}
	return addr, true
}

// resolve_runtime: defaults ← config file ← CLI (non-zero / non-empty / explicit flags win).
resolve_runtime :: proc(opt: Options, allocator := context.allocator) -> (rt: Runtime, ok: bool) {
	path := opt.config
	try_default := false
	if path == "" {
		path = DEFAULT_CONFIG_PATH
		try_default = true
	}

	file_cfg, loaded, missing, err_msg := load_file_config(path, allocator)
	if err_msg != "" {
		fmt.eprintfln("%s %s", paint(.Err, "error:"), err_msg)
		return {}, false
	}
	if missing && !try_default {
		fmt.eprintfln("%s cannot read config %s", paint(.Err, "error:"), path)
		return {}, false
	}
	if loaded {
		log.infof("config: loaded %s", path)
		rt.config_path = path
	} else {
		file_cfg = file_config_defaults()
	}

	rt.listen_port = file_cfg.listen_port if file_cfg.listen_port != 0 else session.DEFAULT_PORT
	rt.download_dir = file_cfg.download_dir if file_cfg.download_dir != "" else "downloads"
	rt.api_host = file_cfg.api_host if file_cfg.api_host != "" else "127.0.0.1"
	rt.api_port = file_cfg.api_port if file_cfg.api_port != 0 else api.DEFAULT_API_PORT
	rt.dht_enabled = file_cfg.dht_enabled
	rt.verbose = opt.verbose

	if opt.port != 0 {
		rt.listen_port = opt.port
	}
	if opt.output != "" {
		rt.download_dir = opt.output
	}
	if opt.api_port != 0 {
		rt.api_port = opt.api_port
	}
	if opt.no_dht {
		rt.dht_enabled = false
	}

	addr, addr_ok := resolve_api_host(rt.api_host)
	if !addr_ok {
		fmt.eprintfln("%s invalid api_host %q", paint(.Err, "error:"), rt.api_host)
		return {}, false
	}
	rt.api_addr = addr
	return rt, true
}
