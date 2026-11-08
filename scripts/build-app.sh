#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building Watvu (release)…"
swift build -c release

APP="$ROOT/Watvu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/Watvu" "$APP/Contents/MacOS/Watvu"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Watvu.icns" "$APP/Contents/Resources/Watvu.icns"

# SwiftPM's generated resource bundle (Bundle.module) — B38: the accessor looks
# for it inside the .app's Resources directory.
if [ -d .build/release/Watvu_Watvu.bundle ]; then
  cp -R .build/release/Watvu_Watvu.bundle "$APP/Contents/Resources/"
fi
# Fallback: localized .strings copied directly (used when Bundle.main is queried).
for lproj in Sources/Watvu/Resources/*.lproj; do
  [ -e "$lproj" ] || continue
  mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
  cp "$lproj"/*.strings "$APP/Contents/Resources/$(basename "$lproj")/"
done

codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
