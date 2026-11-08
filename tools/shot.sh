#!/bin/sh
# Runs the translated app for N seconds and screenshots its largest window
# into build/shot.png (needs build/winbig, compiled from tools/winbig.swift).
cd "$(dirname "$0")/.."
# a run right after another waits for the old process (and its virtual display) to be gone
# test runs get a home of their own (on this volume), with fresh preferences
: ${PPC_HOME:=$PWD/build/home}; export PPC_HOME
mkdir -p "$PPC_HOME/Library/Preferences/AppleWorks" "$PPC_HOME/Documents" "$PPC_HOME/tmp"
rm -f "$PPC_HOME/Library/Preferences/AppleWorks/AppleWorks 6 Preferences"
N=0; while pgrep -x AppleWorks >/dev/null && [ $N -lt 20 ]; do sleep 1; N=$((N + 1)); done
[ build/winbig -nt tools/winbig.swift ] || swiftc -O -o build/winbig tools/winbig.swift
PPC_HOME=$PPC_HOME PPC_VDISPLAY=${PPC_VDISPLAY-1} PPC_STAY_ACTIVE=${PPC_STAY_ACTIVE:-1} PPC_VERBOSE=${PPC_VERBOSE:-1} "build/AppleWorks 6.app/Contents/MacOS/AppleWorks" "$@" > build/run.log 2>&1 &
P=$!
sleep ${SECS:-12}
W=$(build/winbig $P)
[ "$W" != 0 ] && screencapture -x -o -l$W build/shot.png && echo "window $W"
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
