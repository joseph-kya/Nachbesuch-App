#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
if [[ -n "$mode" && "$mode" != "--unsigned" ]]; then
  echo 'Usage: bash scripts/archive.sh [--unsigned]' >&2
  exit 2
fi
signing=()
if [[ "$mode" == "--unsigned" ]]; then
  python3 scripts/app_store_preflight.py
  signing=(CODE_SIGNING_ALLOWED=NO)
else
  python3 scripts/app_store_preflight.py --submission
fi
archive_path="${NACHBESUCH_ARCHIVE_PATH:-/tmp/Nachbesuch-AppStore-$(date +%Y%m%d-%H%M%S).xcarchive}"
xcodebuild -project NachbesuchV5.xcodeproj -scheme NachbesuchV5 \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/nachbesuch-appstore-derived \
  -archivePath "$archive_path" "${signing[@]}" archive
python3 scripts/app_store_preflight.py --app "$archive_path/Products/Applications/NachbesuchV5.app"
printf 'Archive: %s\n' "$archive_path"
