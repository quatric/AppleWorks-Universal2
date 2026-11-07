#!/bin/bash
# Opens one document type from Starting Points, runs scripted input, and
# screenshots the document as build/i_TAG.png.
# usage: tools/input.sh X TAG "t:cmd;t:cmd;..."
#   X    the x of the type's icon in Starting Points (WP 50, SS 150, DB 250, DR 350, PT 450, PR 550)
#   T    seconds before the screenshot (default 24); SECS, the run's length (default 26)
cd "$(dirname "$0")/.."
B=$PWD/build
PPC_SCRIPT="10:wclick Starting $1 60;$3;${T:-24}:shot $B/i_$2.png untitled" SECS=${SECS:-26} sh tools/run.sh > build/irun_$2.txt 2>&1
cp build/run.log build/irun_$2.log
echo "== $2: $(sed -n '/unimplemented imports reached/{n;p;}' build/irun_$2.txt)"
