#!/usr/bin/env python3
"""Check 64-bit native ELF load-segment alignment inside an APK or AAB."""
import argparse
import struct
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifact')
args = parser.parse_args()
failures = []
checked = 0
with zipfile.ZipFile(args.artifact) as archive:
    for name in archive.namelist():
        if not name.endswith('.so') or not any('/' + abi + '/' in name for abi in ('arm64-v8a', 'x86_64')):
            continue
        data = archive.read(name)
        if data[:6] != b'\x7fELF\x02\x01':
            failures.append(name + ': expected little-endian ELF64')
            continue
        offset = struct.unpack_from('<Q', data, 32)[0]
        entry_size, count = struct.unpack_from('<HH', data, 54)
        alignments = []
        for i in range(count):
            pos = offset + i * entry_size
            if struct.unpack_from('<I', data, pos)[0] == 1:
                alignments.append(struct.unpack_from('<Q', data, pos + 48)[0])
        checked += 1
        if not alignments or min(alignments) < 16384:
            failures.append(name + ': load segments do not support 16 KB alignment')
        else:
            print('PASS:', name)
if failures:
    raise SystemExit('\n'.join(failures))
print(f'Checked {checked} native libraries. ELF alignment passed; this does not replace a 16 KB device test.')
