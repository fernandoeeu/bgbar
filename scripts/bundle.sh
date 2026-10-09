#!/usr/bin/env bash
# Monta build/BGBar.app a partir do build release do SwiftPM.
# Uso: scripts/bundle.sh [--install] [--open]
#   SCRATCH_PATH=/caminho  repassado ao swift build como --scratch-path (padrão: .build)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="BGBar"
BUNDLE_ID="dev.fernandoeeu.bgbar"
VERSION="1.0"
BUILD_NUMBER="1"

INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    -h|--help)
      echo "Uso: scripts/bundle.sh [--install] [--open]"
      exit 0 ;;
    *)
      echo "Argumento desconhecido: $arg" >&2
      exit 64 ;;
  esac
done

SWIFT_ARGS=(-c release)
if [[ -n "${SCRATCH_PATH:-}" ]]; then
  SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH")
fi

echo "==> swift build ${SWIFT_ARGS[*]}"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "Binário não encontrado: $BIN" >&2
  exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> Montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Copia recursos extras (ex.: ícone), se existirem.
if [[ -d "$ROOT/Resources" ]]; then
  find "$ROOT/Resources" -maxdepth 1 -type f ! -name 'Info.plist' -exec cp {} "$APP/Contents/Resources/" \;
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>pt-BR</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © $(date +%Y) Fernando Antonio. Todos os direitos reservados.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Assinando (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

FINAL="$APP"
if [[ "$INSTALL" -eq 1 ]]; then
  echo "==> Instalando em /Applications"
  pkill -x "$APP_NAME" || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  FINAL="/Applications/$APP_NAME.app"
fi

if [[ "$OPEN" -eq 1 ]]; then
  echo "==> Abrindo $FINAL"
  open "$FINAL"
fi

echo "$FINAL"
