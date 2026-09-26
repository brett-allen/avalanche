package main

import "core:log"

setup_logging :: proc(verbose: bool) {
	level: log.Level = .Debug if verbose else .Info
	opts := log.Options{.Level, .Date, .Time, .Terminal_Color}
	if verbose {
		opts += {.Short_File_Path, .Line, .Procedure}
	}
	context.logger = log.create_console_logger(level, opts)
}
