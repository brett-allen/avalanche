package main

import "core:fmt"
import "core:terminal"
import "core:terminal/ansi"

Style :: enum {
	None,
	Label,
	Value,
	Ok,
	Warn,
	Err,
	Muted,
}

color_on :: proc() -> bool {
	return terminal.color_enabled && !terminal.is_dumb
}

style_code :: proc(s: Style) -> string {
	if !color_on() {
		return ""
	}
	switch s {
	case .None:
		return ""
	case .Label:
		return ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
	case .Value:
		return ansi.CSI + ansi.BOLD + ansi.SGR
	case .Ok:
		return ansi.CSI + ansi.FG_GREEN + ansi.SGR
	case .Warn:
		return ansi.CSI + ansi.FG_YELLOW + ansi.SGR
	case .Err:
		return ansi.CSI + ansi.FG_RED + ansi.SGR
	case .Muted:
		return ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
	}
	return ""
}

reset_code :: proc() -> string {
	if !color_on() {
		return ""
	}
	return ansi.CSI + ansi.RESET + ansi.SGR
}

paint :: proc(s: Style, text: string) -> string {
	if s == .None || !color_on() {
		return text
	}
	return fmt.tprintf("%s%s%s", style_code(s), text, reset_code())
}

kv :: proc(label, value: string, value_style: Style = .Value) {
	fmt.printfln("%s%-10s%s %s", style_code(.Label), label, reset_code(), paint(value_style, value))
}

section :: proc(title: string) {
	fmt.printfln("%s%s%s", style_code(.Muted), title, reset_code())
}

human_bytes :: proc(n: i64, allocator := context.temp_allocator) -> string {
	if n < 0 {
		return "—"
	}
	if n < 1024 {
		return fmt.tprintf("%d B", n)
	}
	units := [?]string{"KiB", "MiB", "GiB", "TiB"}
	v := f64(n)
	for unit in units {
		v /= 1024
		if v < 1024 {
			if v >= 100 {
				return fmt.tprintf("%.0f %s", v, unit)
			}
			if v >= 10 {
				return fmt.tprintf("%.1f %s", v, unit)
			}
			return fmt.tprintf("%.2f %s", v, unit)
		}
	}
	return fmt.tprintf("%.2f PiB", v / 1024)
}

short_hash :: proc(hex: string) -> string {
	if len(hex) <= 16 {
		return hex
	}
	return fmt.tprintf("%s…%s", hex[:8], hex[len(hex) - 8:])
}

pct :: proc(done, total: i64) -> int {
	if total <= 0 {
		return 0
	}
	return int((done * 100) / total)
}

bar :: proc(done, total: i64, width: int = 16) -> string {
	if width <= 0 {
		return ""
	}
	filled := 0
	if total > 0 {
		filled = int((done * i64(width)) / total)
		if filled > width {
			filled = width
		}
	}
	buf := make([]byte, width, context.temp_allocator)
	for i in 0 ..< width {
		buf[i] = '#' if i < filled else '-'
	}
	return string(buf)
}

// cursor_up moves the cursor up `n` lines (no-op if n <= 0).
cursor_up :: proc(n: int) {
	if n <= 0 {
		return
	}
	fmt.printf("%s%dA", ansi.CSI, n)
}

clear_line :: proc() {
	fmt.printf("%s2K\r", ansi.CSI)
}
