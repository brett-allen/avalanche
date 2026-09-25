#!/bin/sh
set -e
cd "$(dirname "$0")"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

mkdir -p build

case "${1:-}" in
test)
	shift
	odin build tools/bencode_smoke \
		-out:build/bencode_smoke \
		-collection:avalanche=src \
		"$@"
	./build/bencode_smoke
	;;
*)
	odin build src/app \
		-out:avalanche \
		-collection:avalanche=src \
		"$@"
	;;
esac
