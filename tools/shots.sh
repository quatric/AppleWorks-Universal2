#!/bin/sh
# Runs the translated app for N seconds (default 15) and screenshots every
# window it has on screen, floating palettes included, into build/win_<title>.png.
cd "$(dirname "$0")/.."
[ build/winlist -nt tools/winlist.swift ] || swiftc -O -o build/winlist tools/winlist.swift
rm -f build/win_*.png
PPC_STAY_ACTIVE=${PPC_STAY_ACTIVE:-1} PPC_VERBOSE=${PPC_VERBOSE:-1} "build/AppleWorks 6.app/Contents/MacOS/AppleWorks" "$@" > build/run.log 2>&1 &
P=$!
sleep ${SECS:-15}
build/winlist $P | awk -F'\t' '$3 == "true" && $1 != "" { print $1 "\t" $2 }' | while IFS='	' read id name; do
	f="build/win_$(echo "${name:-$id}" | tr -c 'A-Za-z0-9\n' _).png"
	screencapture -x -o -l$id "$f" && echo "$f"
done
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
true
