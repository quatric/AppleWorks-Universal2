#!/usr/bin/env python3
"""Info.plist and icon of a translated CFM application bundle, from the
original's resources ('vers' 1, the 'icns' of the application's BNDL/FREF).

usage: mkinfo.py <original file> <executable name> <display name> <bundle>
"""
import os
import plistlib
import re
import struct
import sys


def resources(path):
    d = open(path + '/..namedfork/rsrc', 'rb').read()
    do, mo, dl, ml = struct.unpack('>IIII', d[:16])
    m = d[mo:mo + ml]
    tl, nl = struct.unpack('>HH', m[24:28])
    n = struct.unpack('>H', m[tl:tl + 2])[0] + 1
    out = {}
    for i in range(n):
        t, cnt, off = struct.unpack('>4sHH', m[tl + 2 + 8 * i:tl + 10 + 8 * i])
        for k in range(cnt + 1):
            rid, no, attr_off, _ = struct.unpack('>hHII', m[tl + off + 12 * k:tl + off + 12 * k + 12])
            o = attr_off & 0xffffff
            ln = struct.unpack('>I', d[do + o:do + o + 4])[0]
            out[(t, rid)] = d[do + o + 4:do + o + 4 + ln]
    return out


def main():
    src, exe, name, app = sys.argv[1:5]
    r = resources(src)
    version = '1.0'
    v = r.get((b'vers', 1))
    if v:
        sl = v[6]
        version = v[7:7 + sl].decode('mac_roman')
    # this port's release (VERSION at the top of the repository: the original's version, the port's
    # release number, the architectures), shown as the version; the build number stays numeric
    port = None
    vf = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'VERSION')
    if os.path.isfile(vf):
        port = open(vf).read().strip() or None
    creator = 'WBwz'
    for (t, rid), data in r.items():
        if t == b'BNDL':
            creator = data[:4].decode('mac_roman')
    icns = [(rid, d) for (t, rid), d in r.items() if t == b'icns']
    info = {
        'CFBundleExecutable': exe,
        'CFBundleName': name,
        'CFBundleDisplayName': name,
        'CFBundleIdentifier': 'com.worldbook.' + exe.lower(),
        'CFBundlePackageType': 'APPL',
        'CFBundleSignature': creator,
        'CFBundleShortVersionString': port or version.split(' ')[0],
        'CFBundleVersion': '.'.join(re.findall(r'\d+', port)[:4]) if port else version.split(' ')[0],
        'CFBundleGetInfoString': port or version,
        'LSMinimumSystemVersion': '11.0',
        'NSHighResolutionCapable': True,
        'NSRequiresAquaSystemAppearance': True,
        'NSPrincipalClass': 'NSApplication',
    }
    # the application's icon: the one the original bundle names (src is its Contents/MacOS/<exe>);
    # the executable's lowest icns resource otherwise (in AppleWorks that is a document's icon)
    contents = os.path.dirname(os.path.dirname(src))
    own = None
    try:
        with open(os.path.join(contents, 'Info.plist'), 'rb') as f:
            orig = plistlib.load(f)
        named = orig.get('CFBundleIconFile')
        # the document types with their icons (the .icns files are copied into Resources), so that
        # Finder shows AppleWorks icons for .cwk, .cws and the rest
        if orig.get('CFBundleDocumentTypes'):
            info['CFBundleDocumentTypes'] = orig['CFBundleDocumentTypes']
        if named:
            path = os.path.join(contents, 'Resources', named if named.endswith('.icns') else named + '.icns')
            if os.path.isfile(path):
                own = open(path, 'rb').read()
    except (OSError, plistlib.InvalidFileException):
        pass
    if own is None and icns:
        icns.sort()
        own = icns[0][1]
    if own is not None:
        open(os.path.join(app, 'Contents/Resources/AppIcon.icns'), 'wb').write(own)
        info['CFBundleIconFile'] = 'AppIcon'
    with open(os.path.join(app, 'Contents/Info.plist'), 'wb') as f:
        plistlib.dump(info, f)
    open(os.path.join(app, 'Contents/PkgInfo'), 'w').write('APPL' + creator)


if __name__ == '__main__':
    main()
