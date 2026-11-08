#!/bin/sh
# Runs the translated app for N seconds (default 20) with the runtime's log
# in build/run.log, then prints the unimplemented imports it reached and the
# end of the log.
cd "$(dirname "$0")/.."
# a run right after another waits for the old process (and its virtual display) to be gone
# test runs get a home of their own (on this volume), with fresh preferences
: ${PPC_HOME:=$PWD/build/home}; export PPC_HOME
mkdir -p "$PPC_HOME/Library/Preferences/AppleWorks" "$PPC_HOME/Documents" "$PPC_HOME/tmp"
rm -f "$PPC_HOME/Library/Preferences/AppleWorks/AppleWorks 6 Preferences"
N=0; while pgrep -x AppleWorks >/dev/null && [ $N -lt 20 ]; do sleep 1; N=$((N + 1)); done
PPC_HOME=$PPC_HOME PPC_VDISPLAY=${PPC_VDISPLAY-1} PPC_STAY_ACTIVE=${PPC_STAY_ACTIVE:-1} PPC_VERBOSE=${PPC_VERBOSE:-1} "build/AppleWorks 6.app/Contents/MacOS/AppleWorks" "$@" > build/run.log 2>&1 &
P=$!
T=0
while [ $T -lt ${SECS:-20} ] && kill -0 $P 2>/dev/null; do sleep 1; T=$((T + 1)); done
if kill -0 $P 2>/dev/null; then echo "== alive at $T s"; kill $P; sleep 1; kill -9 $P 2>/dev/null; else wait $P; echo "== exited ($?) after $T s"; fi
echo "== unimplemented imports reached:"; grep -o 'unimplemented import [A-Za-z0-9_]*' build/run.log | awk '!s[$0]++' | sed 's/unimplemented import //' | tr '\n' ' '; echo
echo "== log tail:"; grep -v 'missing:\|unimplemented import' build/run.log | tail -${N:-25} | cut -c1-220
