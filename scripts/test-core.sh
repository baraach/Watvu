#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build
echo "Compiling core tests…"
swiftc -O \
  Sources/Watvu/Models.swift \
  Sources/Watvu/M3UParser.swift \
  Sources/Watvu/EPGParser.swift \
  Sources/Watvu/Catchup.swift \
  Sources/Watvu/XtreamClient.swift \
  Sources/Watvu/PlaybackEngine.swift \
  Sources/Watvu/SubtitleParser.swift \
  Sources/Watvu/CastProtocol.swift \
  Sources/Watvu/MediaServerClient.swift \
  Sources/Watvu/PlexClient.swift \
  Sources/Watvu/LibraryIndex.swift \
  Tests/CoreTests/main.swift \
  -o .build/core-tests
exec .build/core-tests
