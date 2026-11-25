#!/bin/sh
# Builds dist/AppleWorks_<VERSION>.dmg (arm64 + x86_64) from game/ (tools/install.sh)
# and build/AppleWorks 6.app (xlate/build.sh): the "AppleWorks 6" folder with the
# translated application in place of the original, and the CD's documentation.
# usage: tools/mkdmg.sh   (PY: a Python with machfs)
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}
S=build/dmgstage
rm -rf $S; mkdir -p $S
$PY -I - <<'PYEOF'
import machfs, os
v = machfs.Volume(); v.read(open('dl/aw.dmg', 'rb').read())
d = 'build/dmgstage/AppleWorks 6 Documentation'
os.makedirs(d)
for k in ('Documentation Info.htm', 'Getting Started With AW 6.pdf'):
    open(os.path.join(d, k), 'wb').write(v['AppleWorks 6 Documentation'][k].data)
PYEOF
cp -R "game/AppleWorks 6" "$S/AppleWorks 6"
rm -rf "$S/AppleWorks 6/AppleWorks 6.app"
cp -R "build/AppleWorks 6.app" "$S/AppleWorks 6/AppleWorks 6.app"
lipo -archs "$S/AppleWorks 6/AppleWorks 6.app/Contents/MacOS/AppleWorks" | grep -q arm64 \
	&& lipo -archs "$S/AppleWorks 6/AppleWorks 6.app/Contents/MacOS/AppleWorks" | grep -q x86_64
cp "build/AppleWorks 6.app/Contents/Resources/AppIcon.icns" $S/.VolumeIcon.icns
SetFile -a C $S
V=$(cat VERSION)
mkdir -p dist; rm -f "dist/AppleWorks_$V.dmg"
if ! hdiutil create -volname "AppleWorks $V" -srcfolder $S -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "dist/AppleWorks_$V.dmg"; then
	# hdiutil create fails ("Resource busy") on some macOS versions: build the HFS+ image with diskutil
	MB=$(( $(du -sm $S | cut -f1) * 12 / 10 + 20 ))
	RW="build/dmgstage.rw.dmg"; rm -f "$RW"
	diskutil image create blank --fs None --size ${MB}m "$RW"
	DEV=$(diskutil image attach --nomount "$RW" | grep -oE '/dev/disk[0-9]+' | head -1)
	diskutil eraseDisk JHFS+ "AppleWorks $V" "${DEV#/dev/}" >/dev/null
	ditto $S "/Volumes/AppleWorks $V"
	SetFile -a C "/Volumes/AppleWorks $V"
	diskutil eject "$DEV" >/dev/null
	diskutil image create from --format UDZO "$RW" "dist/AppleWorks_$V.dmg"
	rm -f "$RW"
fi
rm -rf $S
