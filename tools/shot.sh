#!/bin/sh
# Runs the translated app for N seconds and screenshots its largest window
# into build/shot.png (needs build/winbig, compiled from tools/winbig.swift).
cd "$(dirname "$0")/.."
[ build/winbig -nt tools/winbig.swift ] || swiftc -O -o build/winbig tools/winbig.swift
PPC_STAY_ACTIVE=${PPC_STAY_ACTIVE:-1} PPC_VERBOSE=${PPC_VERBOSE:-1} "build/AppleWorks 6.app/Contents/MacOS/AppleWorks" "$@" > build/run.log 2>&1 &
P=$!
sleep ${SECS:-12}
W=$(build/winbig $P)
[ "$W" != 0 ] && screencapture -x -o -l$W build/shot.png && echo "window $W"
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
