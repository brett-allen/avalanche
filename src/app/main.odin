package main

import "core:flags"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		usage()
		os.exit(1)
	}

	opt: Options
	flags.parse_or_exit(&opt, os.args, .Unix)

	cmd, ok := parse_command(opt.command)
	if !ok {
		fmt.eprintfln("Error: invalid command %q. Expected one of: version, info, download, serve.", opt.command)
		usage()
		os.exit(1)
	}

	if !validate(opt, cmd) {
		os.exit(1)
	}

	switch cmd {
	case .Version:
		run_version()
	case .Info:
		run_info(opt)
	case .Download:
		run_download(opt)
	case .Serve:
		run_serve(opt)
	}
}
