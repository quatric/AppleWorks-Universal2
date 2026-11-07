#!/bin/sh
# Installs AppleWorks 6.2.9 into game/ from the original CD image, the way the
# installer's Mac OS X actions would: the VISE archive is unpacked with
# tools/unvise.py, then the Carbon executable (staged in AW6-MacOS) goes into
# the bundle and Info-macos.plist becomes its Info.plist. The Mac OS 8/9
# components (Classic executable, translators, Equation Editor) are left out.
# usage: tools/install.sh <AppleWorks_6.2.9.dmg>
#   needs a Python with machfs (HFS volumes); PY=/path/to/python
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}
DMG=$1
mkdir -p dl
hdiutil convert "$DMG" -format UDRW -o dl/aw.dmg -ov >/dev/null
# the CD is an HFS (not HFS+) volume: take the installer with its resource fork
$PY -I - <<'PYEOF'
import machfs
v = machfs.Volume()
v.read(open('dl/aw.dmg', 'rb').read())
f = v['US and Canadian Installer']
open('dl/installer', 'wb').write(f.data)
open('dl/installer/..namedfork/rsrc', 'wb').write(f.rsrc)
PYEOF
rm -rf dl/out
$PY -I tools/unvise.py dl/installer dl/out > dl/unvise.log
rm -rf game/AppleWorks\ 6
cp -R "dl/out/AppleWorks 6" game/
A="game/AppleWorks 6/AppleWorks 6.app"
rm -f "$A/AppleWorks 6" "$A/Contents/MacOS/"* "game/AppleWorks 6/AppleWorks 6"   # placeholders, Classic build
mkdir -p "$A/Contents/MacOS"
cp "dl/out/AW6-MacOS/AppleWorks 6" "$A/Contents/MacOS/AppleWorks 6"
cat "dl/out/AW6-MacOS/AppleWorks 6/..namedfork/rsrc" > "$A/Contents/MacOS/AppleWorks 6/..namedfork/rsrc"
mv "$A/Contents/Info-macos.plist" "$A/Contents/Info.plist"
# Mac OS X only: drop the Mac OS 8/9 components the archive carries beside the
# Carbon ones (the app picks Carbon/ and DataViz_Carbon/ itself on Mac OS X)
E="game/AppleWorks 6/AppleWorks Essentials"
rm -rf "$E/Translators/Classic" "$E/Equation Editor/Equation Editor" "$E/Equation Editor/Equation Editor Help" \
	"game/AppleWorks 6/Late-breaking News/For Mac OS 8 & 9" "game/AppleWorks 6/Starting Points/Assistants/Classic" \
	"$A/Contents/MacOSClassic"
# shared components the installer puts beside the application; the top-level
# Translators and MacLinkPlus folders are the Classic DataViz set, whose Carbon
# build is already in AppleWorks Essentials/Translators/DataViz_Carbon
for d in "MacOS Help" Fonts; do
	[ -d "dl/out/$d" ] && cp -R "dl/out/$d" "game/AppleWorks 6/.$d" || true
done
# every PowerPC executable left must be a Carbon one
$PY -I tools/carboncheck.py "game/AppleWorks 6"
echo "game/AppleWorks 6"
