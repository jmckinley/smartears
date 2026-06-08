#!/usr/bin/env bash
#
# Build, sign, and upload SmartEars to TestFlight.
#
# Usage:
#   scripts/testflight.sh archive   # archive + export a signed .ipa
#   scripts/testflight.sh upload    # upload the exported .ipa to App Store Connect
#   scripts/testflight.sh release   # archive + export + upload (the full pipeline)
#
# Upload auth uses an App Store Connect API key (the same kind you already use
# for ShelfIQ). Provide these via env vars (never commit the .p8):
#   ASC_KEY_ID     e.g. 2X9ABC3DEF
#   ASC_ISSUER_ID  e.g. 69a6de70-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ASC_KEY_PATH   path to AuthKey_<KEY_ID>.p8  (default: ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8)
#
# Alternatively, skip `upload` and drag the .ipa from build/export into Xcode's
# Organizer / Transporter — that path needs no API key.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Auto-load App Store Connect API credentials if present (gitignored).
# Copy Config/asc.env.example -> Config/asc.env and fill in your IDs.
if [[ -f "Config/asc.env" ]]; then
  # shellcheck disable=SC1091
  source "Config/asc.env"
fi

SCHEME="SmartEars"
PROJECT="SmartEars.xcodeproj"
ARCHIVE_PATH="build/SmartEars.xcarchive"
EXPORT_DIR="build/export"
EXPORT_OPTS="Config/ExportOptions.plist"

ensure_project() {
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null
}

# App Store Connect API key auth for HEADLESS signing/provisioning. Without this,
# command-line xcodebuild cannot use the account you added in the Xcode GUI and
# fails with "No Account for Team". With it, archive/export/upload are hands-off.
ASC_AUTH_ARGS=()
resolve_auth() {
  local key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "$key_path" ]]; then
    ASC_AUTH_ARGS=(
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
      -authenticationKeyPath "$key_path"
    )
  else
    echo "WARNING: App Store Connect API key not found — falling back to interactive"
    echo "         signing. Set ASC_KEY_ID/ASC_ISSUER_ID in Config/asc.env and put"
    echo "         AuthKey_<KEY_ID>.p8 in ~/.appstoreconnect/private_keys/ for headless runs."
  fi
}

do_archive() {
  ensure_project
  resolve_auth
  echo "==> Archiving $SCHEME (Release, generic iOS device)…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates ${ASC_AUTH_ARGS[@]+"${ASC_AUTH_ARGS[@]}"} \
    clean archive

  echo "==> Exporting signed .ipa…"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -allowProvisioningUpdates ${ASC_AUTH_ARGS[@]+"${ASC_AUTH_ARGS[@]}"}
  echo "==> Exported: $(ls "$EXPORT_DIR"/*.ipa 2>/dev/null || echo '(no ipa found)')"
}

do_upload() {
  : "${ASC_KEY_ID:?set ASC_KEY_ID}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  local key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  local ipa
  ipa="$(ls "$EXPORT_DIR"/*.ipa | head -1)"
  echo "==> Uploading $ipa to App Store Connect / TestFlight…"
  xcrun altool --upload-app -f "$ipa" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "==> Done. New build will appear in TestFlight after processing (a few minutes)."
}

case "${1:-release}" in
  archive) do_archive ;;
  upload)  do_upload ;;
  release) do_archive; do_upload ;;
  *) echo "usage: $0 {archive|upload|release}"; exit 1 ;;
esac
