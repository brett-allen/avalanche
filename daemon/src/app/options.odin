package main

import "core:fmt"
import "core:os"
import "core:strings"

Command :: enum {
	Version,
	Info,
	Download,
	Serve,
}

Options :: struct {
	command: string `args:"pos=0" usage:"Command: version | info | download | serve (default)"`,
	input:   string `args:"pos=1" usage:"Path to .torrent or magnet URI"`,
	output:      string `usage:"Download directory (overrides config)"`,
	port:        u16    `usage:"BitTorrent listen port (overrides config)"`,
	api_port:    u16    `args:"name=api-port" usage:"HTTP API listen port (overrides config)"`,
	config:      string `usage:"Path to JSON config file (default avalanche.json)"`,
	no_announce: bool   `args:"name=no-announce" usage:"Do not contact HTTP trackers"`,
	no_dht:      bool   `args:"name=no-dht" usage:"Disable DHT even if enabled in config"`,
	verbose:     bool   `args:"name=verbose" usage:"Debug logging (file:line + dial detail)"`,
}

parse_command :: proc(cmd: string) -> (Command, bool) {
	if cmd == "" {
		return .Serve, true
	}
	v, _ := strings.to_lower(cmd)
	switch v {
	case "version", "-v", "--version":
		return .Version, true
	case "info":
		return .Info, true
	case "download":
		return .Download, true
	case "serve":
		return .Serve, true
	}
	return .Version, false
}

validate :: proc(opt: Options, cmd: Command) -> bool {
	switch cmd {
	case .Version, .Serve:
		return true
	case .Info, .Download:
		if opt.input == "" {
			fmt.eprintfln("Error: %s requires a .torrent path or magnet URI.", opt.command)
			return false
		}
	}
	return true
}

usage :: proc() {
	fmt.eprintf(
		"Usage: %s [command] [input] [flags]\n\n" +
		"With no command, starts the HTTP control-plane daemon.\n\n" +
		"Commands:\n" +
		"  version              Print Avalanche and libcurl versions\n" +
		"  info <torrent>       Inspect a .torrent or magnet URI\n" +
		"  download <t>…        Download one or more magnets/.torrent files\n" +
		"  serve                Run local HTTP control-plane API (default)\n\n" +
		"Flags:\n" +
		"  --config <path>      JSON config file (default ./%s if present)\n" +
		"  --output <dir>       Download directory (overrides config)\n" +
		"  --port <n>           BitTorrent listen port (overrides config)\n" +
		"  --api-port <n>       HTTP API port (overrides config)\n" +
		"  --no-dht             Disable DHT\n" +
		"  --no-announce        Do not contact trackers\n" +
		"  --verbose            Debug logging (file:line + dial detail)\n\n" +
		"Config keys: listen_port, download_dir, api_host, api_port, dht_enabled\n",
		os.args[0],
		DEFAULT_CONFIG_PATH,
	)
}
