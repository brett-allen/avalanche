package main

import "core:fmt"
import "core:os"
import "core:strings"
import "avalanche:session"

Command :: enum {
	Version,
	Info,
	Download,
}

Options :: struct {
	command: string `args:"pos=0,required" usage:"Command: version | info | download"`,
	input:   string `args:"pos=1" usage:"Path to .torrent or magnet URI"`,
	output:      string `usage:"Download directory"`,
	port:        u16    `usage:"Listen port (default 6881)"`,
	no_announce: bool   `args:"name=no-announce" usage:"Do not contact HTTP trackers"`,
	verbose:     bool   `args:"name=verbose" usage:"Show tracker/peer protocol detail"`,
}

parse_command :: proc(cmd: string) -> (Command, bool) {
	v, _ := strings.to_lower(cmd)
	switch v {
	case "version", "-v", "--version":
		return .Version, true
	case "info":
		return .Info, true
	case "download":
		return .Download, true
	}
	return .Version, false
}

validate :: proc(opt: Options, cmd: Command) -> bool {
	switch cmd {
	case .Version:
		return true
	case .Info, .Download:
		if opt.input == "" {
			fmt.eprintfln("Error: %s requires a .torrent path or magnet URI.", opt.command)
			return false
		}
	}
	return true
}

listen_port :: proc(opt: Options) -> u16 {
	return opt.port if opt.port != 0 else session.DEFAULT_PORT
}

usage :: proc() {
	fmt.eprintf(
		"Usage: %s <command> [input] [flags]\n\n" +
		"Commands:\n" +
		"  version              Print Avalanche and libcurl versions\n" +
		"  info <torrent>       Inspect a .torrent or magnet URI\n" +
		"  download <t>…        Download one or more magnets/.torrent files\n\n" +
		"Flags:\n" +
		"  --output <dir>       Download directory\n" +
		"  --port <n>           Listen port (default %d)\n" +
		"  --no-announce        Do not contact trackers\n" +
		"  --verbose            Show tracker/peer protocol detail\n",
		os.args[0],
		int(session.DEFAULT_PORT),
	)
}
