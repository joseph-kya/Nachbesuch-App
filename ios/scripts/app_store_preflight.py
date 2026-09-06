#!/usr/bin/env python3
"""Local release checks. --submission additionally requires publishing details."""
import argparse
import plistlib
import re
import struct
import sys
from pathlib import Path
from urllib.parse import urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--submission', action='store_true')
parser.add_argument('--app', type=Path, help='Also inspect a compiled .app bundle')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = root / 'NachbesuchV5'
errors = []
missing = []


def check_resources(folder):
    try:
        metadata = plistlib.loads((folder / 'AppStoreMetadata.plist').read_bytes())
        for key in ('DeveloperName', 'SupportEmail', 'SupportURL', 'PrivacyPolicyURL'):
            value = metadata.get(key, '').strip()
            if not value:
                missing.append(f'{folder.name}: {key}')
            elif key.endswith('URL'):
                url = urlparse(value)
                if url.scheme != 'https' or not url.hostname or url.hostname in ('example.com', 'example.org', 'example.net', 'localhost') or url.hostname.endswith(('.invalid', '.test', '.localhost', '.example')):
                    errors.append(f'{key} must be a real public HTTPS URL')
            elif key == 'SupportEmail' and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value):
                errors.append('SupportEmail must be an email address')
        manifest = plistlib.loads((folder / 'PrivacyInfo.xcprivacy').read_bytes())
        reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons']
                   for item in manifest['NSPrivacyAccessedAPITypes']}
        for category, reason in [('UserDefaults', 'CA92.1'), ('FileTimestamp', 'C617.1')]:
            if reason not in reasons.get('NSPrivacyAccessedAPICategory' + category, []):
                errors.append(f'Missing privacy reason: {category} / {reason}')
        if not (folder / 'PrivacyPolicy.txt').read_text().strip():
            errors.append('Bundled privacy information is empty')
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(f'{folder}: {error}')


check_resources(source)
icons = list((source / 'Assets.xcassets' / 'AppIcon.appiconset').glob('*.png'))
if not icons:
    errors.append('Missing App Store icon')
for icon in icons:
    data = icon.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 33:
        errors.append(f'Invalid PNG: {icon.name}')
        continue
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    if (width, height) != (1024, 1024) or color in (4, 6):
        errors.append(f'{icon.name}: expected 1024×1024 without alpha')
    offset = 8
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        if data[offset + 4:offset + 8] == b'tRNS':
            errors.append(f'{icon.name}: transparency is not allowed')
        offset += size + 12

if args.app:
    check_resources(args.app)
    try:
        info = plistlib.loads((args.app / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'at.volkshilfe.nachbesuch.v6':
            errors.append('Unexpected app bundle identifier')
        if info.get('MinimumOSVersion') != '18.0':
            errors.append('Expected iOS 18.0 deployment target')
        sdk = info.get('DTSDKName', '')
        if not sdk.startswith('iphoneos') or int(re.search(r'\d+', sdk)[0]) < 26:
            errors.append('Submission requires an iOS device build with SDK 26 or later')
    except (OSError, ValueError, TypeError) as error:
        errors.append(f'Compiled app: {error}')

for error in errors:
    print('ERROR:', error)
for item in missing:
    print('PUBLISHING DETAIL REQUIRED:', item)
if errors or (args.submission and missing):
    sys.exit(1)
print('Technical resource checks passed.' + (' Publishing configuration remains incomplete.' if missing else ''))
