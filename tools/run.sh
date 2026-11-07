#!/bin/sh
# Runs the translated app for N seconds (default 20) with the runtime's log
# in build/run.log, then prints the unimplemented imports it reached and the
# end of the log.
cd "$(dirname "$0")/.."
PPC_STAY_ACTIVE=${PPC_STAY_ACTIVE:-1} PPC_VERBOSE=${PPC_VERBOSE:-1} "build/AppleWorks 6.app/Contents/MacOS/AppleWorks" "$@" > build/run.log 2>&1 &
P=$!
T=0
while [ $T -lt ${SECS:-20} ] && kill -0 $P 2>/dev/null; do sleep 1; T=$((T + 1)); done
if kill -0 $P 2>/dev/null; then echo "== alive at $T s"; kill $P; sleep 1; kill -9 $P 2>/dev/null; else wait $P; echo "== exited ($?) after $T s"; fi
echo "== unimplemented imports reached:"; grep -o 'unimplemented import [A-Za-z0-9_]*' build/run.log | awk '!s[$0]++' | sed 's/unimplemented import //' | tr '\n' ' '; echo
echo "== log tail:"; grep -v 'missing:\|unimplemented import' build/run.log | tail -${N:-25} | cut -c1-220
