#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:---test-package}"
if [[ "$MODE" != "--test-package" ]]; then
  echo 'Formal distribution requires verified runtime provenance, Developer ID signing and notarization; only --test-package is implemented.' >&2
  exit 2
fi
PYTHON="${BUILD_PYTHON:-$ROOT/work/build-env/bin/python}"
[[ -x "$PYTHON" ]] || { echo 'Create a clean build environment and install packaging/macos/requirements-build.txt first.' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'This build targets Apple Silicon.' >&2; exit 2; }
RUNTIME="${TUNNEL_CLIENT_PATH:-$ROOT/tunnel-client}"
[[ -x "$RUNTIME" ]] || { echo 'Set TUNNEL_CLIENT_PATH to the matching runtime binary.' >&2; exit 2; }
EXPECTED="$("$PYTHON" -c 'import json; print(json.load(open("packaging/macos/runtime-manifest.json"))["sha256"])')"
ACTUAL="$(shasum -a 256 "$RUNTIME" | cut -d ' ' -f 1)"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Tunnel runtime checksum mismatch.' >&2; exit 2; }
export PYINSTALLER_CONFIG_DIR="$ROOT/work/pyinstaller-cache"
"$PYTHON" -m PyInstaller --noconfirm --distpath build/macos --workpath work/pyinstaller packaging/macos/server.spec
swift build --package-path desktop/macos --scratch-path work/swift-release --cache-path work/swift-cache -c release
SWIFT_BIN="$(swift build --package-path desktop/macos --scratch-path work/swift-release --cache-path work/swift-cache -c release --show-bin-path)"
mkdir -p build/macos dist
STAGE="$(mktemp -d "$ROOT/build/macos/app-stage.XXXXXX")"
APP="$STAGE/Project MCP.app"
RES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RES/runtime" "$RES/licenses/tunnel-client"
cp packaging/macos/Info.plist "$APP/Contents/Info.plist"
cp "$SWIFT_BIN/ProjectMCPApp" "$SWIFT_BIN/ProjectMCPSupervisor" "$APP/Contents/MacOS/"
ditto build/macos/server "$RES/server"
cp "$RUNTIME" "$RES/runtime/tunnel-client"
cp packaging/macos/runtime-manifest.json "$RES/runtime/manifest.json"
ICON="$ROOT/project_mcp_icon.png"
[[ -f "$ICON" ]] || { echo 'Missing app icon source project_mcp_icon.png.' >&2; exit 2; }
sips -z 512 512 "$ICON" --out "$RES/AppIcon.png" >/dev/null
cp packaging/macos/licenses/* "$RES/licenses/tunnel-client/"
"$PYTHON" scripts/package-licenses.py "$RES/licenses/python"
cp docs/macos-app.md "$RES/README.md"
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ICON" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ICON" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
codesign --force --deep --sign - "$APP"
if [[ -e 'dist/Project MCP.app' ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' 'dist/Project MCP.app/Contents/Info.plist')" == com.sc61561.project-mcp ]] || { echo 'Unexpected existing app; refusing to replace.' >&2; exit 2; }
  mv 'dist/Project MCP.app' "$STAGE/Previous Project MCP.app"
fi
ditto "$APP" 'dist/Project MCP.app'
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Project-MCP-macOS-arm64-test.zip
shasum -a 256 dist/Project-MCP-macOS-arm64-test.zip > dist/Project-MCP-macOS-arm64-test.zip.sha256
bash scripts/verify-macos.sh 'dist/Project MCP.app'
echo "Test bundle: $ROOT/dist/Project MCP.app"
echo "Test archive: $ROOT/dist/Project-MCP-macOS-arm64-test.zip"
