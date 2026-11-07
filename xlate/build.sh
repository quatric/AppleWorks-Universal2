#!/bin/sh
# Translates AppleWorks 6 (PowerPC Carbon CFM application) into
# build/AppleWorks 6.app.
# usage: xlate/build.sh [lift]
set -e
cd "$(dirname "$0")/.."
CC="clang -arch arm64 -mmacosx-version-min=11.0"
PY=${PY:-python3}
NAME="AppleWorks 6"
SRC="game/AppleWorks 6/AppleWorks 6.app/Contents/MacOS/AppleWorks 6"
OUT=build/ppc/aw
# the Mac OS X (Carbon) build only, never the Mac OS 8/9 one
$PY -I tools/carboncheck.py "$SRC" | grep -q ', 0 Classic' && $PY -I -c 'import sys; sys.path.insert(0, "xlate"); from pef import PEF; sys.exit("CarbonLib" not in [l[0] for l in PEF(sys.argv[1]).libs])' "$SRC" \
	|| { echo "$SRC is not the Carbon (Mac OS X) build; run tools/install.sh" >&2; exit 1; }
if [ "$1" = lift ] || [ ! -d $OUT/x ]; then
	mkdir -p $OUT/x
	$PY -I xlate/liftppc.py "$SRC" $OUT/x
fi
find $OUT/x -name '*.c' | while read c; do
	o=$c.o
	if [ ! -f $o ] || [ $c -nt $o ] || [ xlate/rt/ppccode.h -nt $o ] || [ xlate/rt/ppc.h -nt $o ]; then echo $c; fi
done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -Ixlate/rt -c {} -o {}.o"
[ -f $OUT/x/blob.S.o ] && [ $OUT/x/blob.S.o -nt $OUT/x/code.bin ] || $CC -c $OUT/x/blob.S -o $OUT/x/blob.S.o
mkdir -p build/ppc/rt
for f in xlate/rt/*.m xlate/rt/*.c; do
	o=build/ppc/rt/$(basename $f).o
	if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find xlate/rt -name '*.h' -newer $o)" ]; then
		echo "cc $f"
		ARC=-fno-objc-arc
		case $(basename $f) in ae.m|nav.m) ARC=-fobjc-arc ;; esac
		$CC -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations $ARC -fno-strict-aliasing -Ixlate/rt -c $f -o $o
	fi
done
EXE=AppleWorks
$CC -o "$OUT/$EXE" build/ppc/rt/*.o $OUT/x/*.o \
	-framework AppKit -framework Foundation -framework Carbon -framework CoreText -framework ImageIO \
	-framework AudioToolbox -framework AVFoundation -framework QuartzCore -framework PDFKit -Wl,-w

# the bundle: the translated executable, the original's resource fork, an icon
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$SRC/..namedfork/rsrc" "$APP/Contents/Resources/Application.rsrc"
cp "game/$NAME/$NAME.app/Contents/Resources/"*.icns "$APP/Contents/Resources/"
$PY -I xlate/mkinfo.py "$SRC" "$EXE" "AppleWorks" "$APP"
echo "$APP"
