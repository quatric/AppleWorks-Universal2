#!/bin/sh
# Installs AppleWorks 6.2.9 into game/ from an "AppleWorks 6" folder made by the
# original installer on Mac OS X (zipped, with its resource forks), keeping only
# the Mac OS X components: the Carbon executable in Contents/MacOS, the Carbon
# translators and Equation Editor, and the Mac OS X help inside the bundle.
# The Mac OS 8/9 components (Contents/MacOSClassic, Classic translators and
# assistants, the Classic Equation Editor) are left out.
# usage: tools/install.sh <AppleWorks 6.zip | AppleWorks 6 folder>
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}
SRC=$1
[ -n "$SRC" ] || { echo "usage: $0 <AppleWorks 6.zip | AppleWorks 6 folder>" >&2; exit 1; }
rm -rf dl/inst; mkdir -p dl/inst
if [ -d "$SRC" ]; then
	ditto "$SRC" "dl/inst/AppleWorks 6"
else
	# ditto puts the __MACOSX entries back as resource forks and Finder info
	ditto -x -k "$SRC" dl/inst
fi
I="dl/inst/AppleWorks 6"
A="$I/AppleWorks 6.app"
X="$A/Contents/MacOS/AppleWorks 6"
[ -s "$X" ] && [ -s "$X/..namedfork/rsrc" ] || { echo "$X (with its resource fork) not found" >&2; exit 1; }
rm -rf game/AppleWorks\ 6; mkdir -p game
ditto "$I" "game/AppleWorks 6"
G="game/AppleWorks 6"
A="$G/AppleWorks 6.app"
mv "$A/Contents/Info-macos.plist" "$A/Contents/Info.plist"
# Mac OS 8/9 only: the Classic executable and its folder aliases, the bundle's
# placeholder file (the application as Mac OS 9 sees the package), Classic
# translators, assistants and Equation Editor; the log names the installing user
E="$G/AppleWorks Essentials"
rm -rf "$A/Contents/MacOSClassic" "$A/AppleWorks 6" \
	"$E/Translators/Classic" "$E/Equation Editor/Equation Editor" "$E/Equation Editor/Equation Editor Help" \
	"$G/Late-breaking News/For Mac OS 8 & 9" "$G/Starting Points/Assistants/Classic" \
	"$G/AppleWorks 6 Installer Log"
# the installer puts its fonts in ~/Library/Fonts; take them from the CD unpack if there
[ -d dl/out/Fonts ] && cp -R dl/out/Fonts "$G/.Fonts" || true
rm -rf dl/inst
/usr/bin/xattr -dr com.apple.quarantine "$G" 2>/dev/null || true
# every PowerPC executable left must be a Carbon one
$PY -I tools/carboncheck.py "$G"
echo "$G"
