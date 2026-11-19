# AppleWorks 6 Universal

AppleWorks 6.2.9 for Mac OS X, running natively on Apple silicon and Intel Macs.

AppleWorks 6 is a PowerPC Carbon (CFM) application. This project translates its
PowerPC code into C, compiles it for arm64 and x86_64, and links it against a
runtime that implements the Mac OS Toolbox and Carbon calls it uses (QuickDraw,
the Window, Control, Menu and Dialog Managers, TextEdit, the Resource and File
Managers, Open Transport, threads and more) on top of AppKit and Core Graphics.

This repository contains only the translator, the runtime and build tools. It
contains no Apple code or data: you need your own copy of AppleWorks 6.2.9.

## Layout

- `xlate/` – the PowerPC-to-C translator (`liftppc.py`, `pef.py`), the build
  script and the runtime (`xlate/rt/`)
- `tools/` – installing AppleWorks from its installer, test-run and screenshot
  helpers, the Starting Points web mirror and DMG packaging

## Building

Requirements: macOS with the Xcode command-line tools, and Python 3.

1. Install AppleWorks 6.2.9 into `game/` from the "AppleWorks 6" folder its
   Mac OS X installer creates (a zip that keeps resource forks, or the folder):

       tools/install.sh "AppleWorks 6.zip"

2. Optionally, rebuild the Starting Points Web tab's content from the
   Internet Archive's copies of Apple's former `awpicts.apple.com` server:

       tools/webmirror.sh

3. Translate and build the universal application into `build/AppleWorks 6.app`:

       xlate/build.sh

4. Optionally, package `dist/AppleWorks_6.2.9-U2B.dmg` (needs a Python with
   `machfs`, passed as `PY`):

       PY=/path/to/python tools/mkdmg.sh

## Running tests

`tools/run.sh` runs the translated app for a while on a virtual display and
prints the end of its log; `PPC_SCRIPT` drives it with scripted clicks, keys,
menu choices and screenshots (see the top of `xlate/rt/script.m`).

## Status

All six document types (word processing, spreadsheet, database, drawing,
painting, presentation) open and edit, Starting Points works including its Web
tab, and links in documents can be followed. Some rarely used Toolbox calls
are still unimplemented.
