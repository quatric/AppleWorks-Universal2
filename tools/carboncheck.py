#!/usr/bin/env python3
# Checks that every PowerPC PEF container under a folder is a Carbon build:
# it imports CarbonLib (or Carbon.framework-era CarbonFrameworkLib) and none of
# the Mac OS 8/9-only libraries. Prints each offender; exits 1 if any.
# usage: tools/carboncheck.py <folder or file>
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'xlate'))
from pef import PEF

CARBON = {'CarbonLib', 'CarbonFrameworkLib'}
CLASSIC = {'InterfaceLib', 'AppearanceLib', 'ControlsLib', 'WindowsLib', 'MenusLib',
           'NavigationLib', 'ThreadsLib', 'ObjectSupportLib', 'DragLib', 'AppleScriptLib'}

bad = 0
n = 0
top = sys.argv[1]
walk = [(os.path.dirname(top), [], [os.path.basename(top)])] if os.path.isfile(top) else os.walk(top)
for root, _, files in walk:
    for f in files:
        p = os.path.join(root, f)
        with open(p, 'rb') as fh:
            if fh.read(12) != b'Joy!peffpwpc':
                continue
        n += 1
        libs = {l[0] for l in PEF(p).libs}
        if libs & CLASSIC:
            print('Classic: %s (%s)' % (p, ', '.join(sorted(libs & CLASSIC))))
            bad += 1
        elif not libs & CARBON:
            # a library that only links other DataViz/MSL libraries is fine if
            # those are Carbon; report it for a look but don't fail on it
            print('no CarbonLib: %s (%s)' % (p, ', '.join(sorted(libs)) or 'no imports'))
print('%d PEF containers checked, %d Classic' % (n, bad))
sys.exit(1 if bad else 0)
