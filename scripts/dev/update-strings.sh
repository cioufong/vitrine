#!/bin/bash
# Adds new UI strings to Sources/VitrineApp/Resources/Localizable.xcstrings and marks removed ones
# stale, from the strings the Swift compiler records while building VitrineApp. Run it after changing
# UI text, then translate the new entries (Xcode's String Catalog editor, or edit the JSON).
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --product VitrineApp >/dev/null
# The newest .stringsdata of each Swift source; those of deleted sources are skipped so their
# strings go stale.
DATA=""
for src in Sources/VitrineApp/*.swift; do
  # shellcheck disable=SC2012
  f=$(find .build -path '*VitrineApp*' -name "$(basename "$src" .swift).stringsdata" -print0 | xargs -0 ls -t 2>/dev/null | head -1)
  [ -n "$f" ] && DATA+=" $f"
done
[ -n "$DATA" ] || { echo "no .stringsdata found; touch a file in Sources/VitrineApp and retry" >&2; exit 1; }
# shellcheck disable=SC2086
xcrun xcstringstool sync Sources/VitrineApp/Resources/Localizable.xcstrings --stringsdata $DATA
python3 - <<'PY'
import json
d = json.load(open("Sources/VitrineApp/Resources/Localizable.xcstrings"))
langs = sorted({l for v in d["strings"].values() for l in v.get("localizations", {})} - {d["sourceLanguage"]})
for l in langs:
    missing = [k for k, v in d["strings"].items()
               if v.get("shouldTranslate", True) and l not in v.get("localizations", {})]
    print(f"{l}: {len(missing)} untranslated")
PY
