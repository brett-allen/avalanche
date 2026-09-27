package main

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"

main :: proc() {
	opt: Options
	if len(os.args) >= 2 {
		flags.parse_or_exit(&opt, os.args, .Unix)
	}

	cmd, ok := parse_command(opt.command)
	if !ok {
		fmt.eprintfln("Error: invalid command %q. Expected one of: version, info, download, serve.", opt.command)
		usage()
		os.exit(1)
	}

	if !validate(opt, cmd) {
		os.exit(1)
	}

	setup_logging(opt.verbose)
	defer log.destroy_console_logger(context.logger)

	rt, rt_ok := resolve_runtime(opt)
	if !rt_ok {
		os.exit(1)
	}

	switch cmd {
	case .Version:
		run_version()
	case .Info:
		run_info(opt, rt)
	case .Download:
		run_download(opt, rt)
	case .Serve:
		run_serve(opt, rt)
	}
}
