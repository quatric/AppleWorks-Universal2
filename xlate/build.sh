#!/bin/sh
# Translates AppleWorks 6 (PowerPC Carbon CFM application) into
# build/AppleWorks 6.app.
# usage: xlate/build.sh [lift]
set -e
cd "$(dirname "$0")/.."
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
EXE=AppleWorks
BINS=
for ARCH in ${ARCHS:-arm64 x86_64}; do
	CC="clang -arch $ARCH -mmacosx-version-min=11.0"
	# objects: .o for arm64 (as before), .$ARCH.o for the others
	if [ $ARCH = arm64 ]; then SFX=; else SFX=.$ARCH; fi
	find $OUT/x -name '*.c' | while read c; do
		o=$c$SFX.o
		if [ ! -f $o ] || [ $c -nt $o ] || [ xlate/rt/ppccode.h -nt $o ] || [ xlate/rt/ppc.h -nt $o ]; then echo $c; fi
	done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -Ixlate/rt -c {} -o {}$SFX.o"
	[ -f $OUT/x/blob.S$SFX.o ] && [ $OUT/x/blob.S$SFX.o -nt $OUT/x/code.bin ] || $CC -c $OUT/x/blob.S -o $OUT/x/blob.S$SFX.o
	mkdir -p build/ppc/rt$SFX
	for f in xlate/rt/*.m xlate/rt/*.c; do
		o=build/ppc/rt$SFX/$(basename $f).o
		if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find xlate/rt -name '*.h' -newer $o)" ]; then
			echo "cc $ARCH $f"
			ARC=-fno-objc-arc
			case $(basename $f) in ae.m|nav.m) ARC=-fobjc-arc ;; esac
			$CC -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations $ARC -fno-strict-aliasing -Ixlate/rt -c $f -o $o
		fi
	done
	$CC -o "$OUT/$EXE$SFX" build/ppc/rt$SFX/*.o $(find $OUT/x -name "*.c$SFX.o") $OUT/x/blob.S$SFX.o \
		-framework AppKit -framework Foundation -framework Carbon -framework CoreText -framework ImageIO \
		-framework AudioToolbox -framework AVFoundation -framework QuartzCore -framework PDFKit -Wl,-w
	BINS="$BINS $OUT/$EXE$SFX"
done
lipo -create $BINS -output "$OUT/$EXE.universal"

# the bundle: the translated executable, the original's resource fork, an icon
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$EXE.universal" "$APP/Contents/MacOS/$EXE"
cp "$SRC/..namedfork/rsrc" "$APP/Contents/Resources/Application.rsrc"
cp "game/$NAME/$NAME.app/Contents/Resources/"*.icns "$APP/Contents/Resources/"
$PY -I xlate/mkinfo.py "$SRC" "$EXE" "AppleWorks" "$APP"
/usr/bin/xattr -cr "$APP"; codesign --force --deep -s - "$APP"
echo "$APP"
