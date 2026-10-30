#!/bin/bash
set -euo pipefail
APP="${1:?Usage: verify-macos.sh path/to/app}"
for FILE in Contents/Info.plist Contents/MacOS/ProjectMCPApp Contents/MacOS/ProjectMCPSupervisor Contents/Resources/server/project-mcp-server Contents/Resources/runtime/tunnel-client Contents/Resources/runtime/manifest.json Contents/Resources/licenses/python/python-packages.json Contents/Resources/licenses/tunnel-client/NOTICE; do
  [[ -f "$APP/$FILE" ]] || { echo "Missing bundle file: $FILE" >&2; exit 1; }
done
for FILE in Contents/MacOS/ProjectMCPApp Contents/MacOS/ProjectMCPSupervisor Contents/Resources/server/project-mcp-server Contents/Resources/runtime/tunnel-client; do
  [[ -x "$APP/$FILE" ]] || { echo "Not executable: $FILE" >&2; exit 1; }
  file "$APP/$FILE" | grep -q arm64 || { echo "Architecture mismatch: $FILE" >&2; exit 1; }
done
if find "$APP" -name '.env' -o -name '*.key' | grep -q .; then
  echo 'Unexpected local configuration or credential file in bundle.' >&2; exit 1
fi
# certifi's public CA bundle is needed for TLS; reject private key contents,
# rather than rejecting all PEM files (which would also reject public CAs).
while IFS= read -r -d '' CERT; do
  if grep -qE 'BEGIN ([A-Z0-9]+ )?PRIVATE KEY' "$CERT"; then
    echo 'Unexpected private key in bundle.' >&2; exit 1
  fi
done < <(find "$APP" -name '*.pem' -print0)
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo 'Bundle checks: OK (ad-hoc signed test package, not notarized)'
