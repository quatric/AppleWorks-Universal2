#!/usr/bin/env python3
"""Extracts a Mac Installer VISE 8 archive (an installer's data fork: 'SVCT').

Format, as worked out from the AppleWorks 6.2.9 installer:
- data fork: the installer engine (PEF), then file data, then a CVCT chunk
  whose header's offset is at +0x24. The CVCT holds a small chunk table and
  the catalog: a deflate stream at CVCT+0x64.
- every stream is zlib deflate (level 9) stored as 16-bit words with the bytes
  of each pair swapped; file data is also run through a fixed 256-byte
  substitution (tools/vise_table.bin, inverse given). The decompressor reads
  words, so a stored block's LEN starts on a 16-bit boundary.
- catalog entries: 'DVCT' folders (id +28, parent +32, name length +80,
  name +160) and 'FVCT' files (type +44, creator +48, compressed and
  unpacked data fork sizes +68/+72, resource fork +76/+80, parent folder
  +88, data offset +100, name length +122, name +198). Entries whose offset
  is 0xfffffffe share another entry's data; type 0 entries are install
  actions, not files.

usage: unvise.py <installer data fork> <out dir> [path prefix to keep...]
Resource forks go to the files' named forks, type/creator to FinderInfo."""
import ctypes
import os
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = open(os.path.join(HERE, 'vise_table.bin'), 'rb').read()
_lib = None


def lib():
    global _lib
    if _lib is None:
        so = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'libviseinflate.dylib')
        src = os.path.join(HERE, 'vise_inflate.c')
        if not os.path.exists(so) or os.path.getmtime(so) < os.path.getmtime(src):
            os.system('clang -O2 -shared -o "%s" "%s"' % (so, src))
        _lib = ctypes.CDLL(so)
        _lib.vise_inflate.restype = ctypes.c_long
        _lib.vise_inflate.argtypes = [ctypes.c_char_p, ctypes.c_long, ctypes.c_char_p, ctypes.c_long]
    return _lib


def unswap(b):
    b = bytearray(b + (b'\0' if len(b) & 1 else b''))
    b[0::2], b[1::2] = b[1::2], b[0::2]
    return bytes(b)


def inflate(stream, ulen):
    out = ctypes.create_string_buffer(max(ulen, 1))
    n = lib().vise_inflate(stream, len(stream), out, ulen)
    if n != ulen:
        raise ValueError('inflate gave %d of %d bytes' % (n, ulen))
    return out.raw[:ulen]


def catalog(d):
    cv = struct.unpack_from('>I', d, 0x24)[0]
    assert d[cv:cv + 4] == b'CVCT'
    size = struct.unpack_from('>I', d, cv + 4)[0]
    return zlib.decompressobj(-15).decompress(unswap(d[cv + 0x64:cv + size + 0x64]))


def entries(cat):
    offs = sorted(set(m.start() for m in re.finditer(rb'[DF]VCT', cat)))
    for i, o in enumerate(offs):
        e = cat[o:offs[i + 1] if i + 1 < len(offs) else len(cat)]
        if e[:4] == b'DVCT' and len(e) >= 160:
            n = e[80]
            yield 'D', o, {'id': struct.unpack_from('>I', e, 28)[0], 'parent': struct.unpack_from('>I', e, 32)[0],
                           'name': e[160:160 + n].decode('mac_roman')}
        elif e[:4] == b'FVCT' and len(e) >= 198:
            n = e[122]
            cd, ud, cr, ur = struct.unpack_from('>4I', e, 68)
            yield 'F', o, {'type': e[44:48], 'creator': e[48:52], 'cd': cd, 'ud': ud, 'cr': cr, 'ur': ur,
                           'parent': struct.unpack_from('>I', e, 88)[0], 'off': struct.unpack_from('>I', e, 100)[0],
                           'flags': struct.unpack_from('>H', e, 56)[0], 'name': e[198:198 + n].decode('mac_roman')}


def fork(d, off, clen, ulen):
    if not ulen:
        return b''
    s = unswap(d[off:off + clen]).translate(TABLE)
    return inflate(s, ulen)


_c = ctypes.CDLL(None)
_c.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]


def setx(path, name, value):
    if _c.setxattr(path.encode(), name.encode(), value, len(value), 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'setxattr %s on %s' % (name, path))


def main():
    src, out = sys.argv[1:3]
    keep = sys.argv[3:]
    d = open(src, 'rb').read()
    folders, files = {}, []
    for kind, o, e in entries(catalog(d)):
        (folders.__setitem__(e['id'], e) if kind == 'D' else files.append(e))

    def path(fid):
        parts = []
        while fid in folders:
            parts.append(folders[fid]['name'].replace('/', ':'))
            fid = folders[fid]['parent']
        if fid != 2:   # the installer's target folder; others are system folders
            parts.append('_system/%x' % fid)
        return '/'.join(reversed(parts))

    seen = {}
    n = skipped = failed = 0
    for e in files:
        if e['type'] == b'\0\0\0\0' or e['off'] >= 0xfffffff0:
            skipped += 1
            continue
        p = (path(e['parent']) + '/' + e['name'].replace('/', ':')).lstrip('/')
        if keep and not any(p.startswith(k) for k in keep):
            continue
        # variants of one path (per system or language): keep them all
        seen[p] = seen.get(p, 0) + 1
        if seen[p] > 1:
            p += ' ~%d' % seen[p]
        dst = os.path.join(out, p)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            data = fork(d, e['off'], e['cd'], e['ud'])
            rsrc = fork(d, e['off'] + e['cd'] + (e['cd'] & 1), e['cr'], e['ur'])
        except ValueError as ex:
            print('FAILED %s: %s' % (p, ex), file=sys.stderr)
            failed += 1
            continue
        open(dst, 'wb').write(data)
        if rsrc:
            setx(dst, 'com.apple.ResourceFork', rsrc)
        setx(dst, 'com.apple.FinderInfo', e['type'] + e['creator'] + bytes(24))
        n += 1
        print('%8d %8d  %s' % (len(data), len(rsrc), p))
    print('%d files written, %d failed, %d actions or shared entries skipped' % (n, failed, skipped), file=sys.stderr)


if __name__ == '__main__':
    main()
