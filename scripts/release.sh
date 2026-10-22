#!/usr/bin/env bash
# Builds, signs, notarizes and publishes an Agent Meter release.
#
# Usage: scripts/release.sh [--skip-notarize] [--no-publish]
#
#   --skip-notarize  Skip notarization (local testing only; Gatekeeper will block the app).
#   --no-publish     Build the ZIP and appcast in build/release but do not create a GitHub
#                    release.
#
# One-time setup:
#   - Developer ID Application certificate in the login keychain.
#   - xcrun notarytool store-credentials "$NOTARY_PROFILE" (default profile: agent-meter-notary).
#   - Sparkle EdDSA key in the login keychain (Sparkle's generate_keys), with the public key set
#     as SPARKLE_PUBLIC_ED_KEY in the Xcode project.
#   - gh auth login
set -euo pipefail

REPO="scolor-dev/agent-meter"
NOTARY_PROFILE="${NOTARY_PROFILE:-agent-meter-notary}"

skip_notarize=false
publish=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) skip_notarize=true ;;
    --no-publish) publish=false ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

if [[ "$skip_notarize" == true && "$publish" == true ]]; then
  echo "Refusing to publish a release that was not notarized. Add --no-publish." >&2
  exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes. Commit them first." >&2
  exit 1
fi

out="$root/build/release"
derived="$out/DerivedData"
archive="$out/AgentMeter.xcarchive"
export_dir="$out/export"
rm -rf "$out"
mkdir -p "$out"

echo "==> Archiving"
xcodebuild \
  -project AgentMeter.xcodeproj \
  -scheme AgentMeter \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" \
  -archivePath "$archive" \
  archive

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$root/scripts/ExportOptions.plist" \
  -exportPath "$export_dir"

app="$export_dir/AgentMeter.app"
info="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info" 2>/dev/null || true)"
tag="v$version"
zip_name="AgentMeter-$version.zip"
zip="$out/$zip_name"

if [[ -z "$public_key" ]]; then
  echo "SUPublicEDKey is empty; set SPARKLE_PUBLIC_ED_KEY in the Xcode project first." >&2
  exit 1
fi

if [[ "$publish" == true ]] && gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $tag already exists. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi

if [[ "$skip_notarize" == false ]]; then
  echo "==> Notarizing $tag ($build)"
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm "$out/notarize.zip"
fi

echo "==> Packaging $zip_name"
ditto -c -k --keepParent "$app" "$zip"
sha256="$(shasum -a 256 "$zip" | awk '{print $1}')"

echo "==> Signing the update for Sparkle"
sign_update="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
# Prints: sparkle:edSignature="..." length="..."
enclosure_attributes="$("$sign_update" "$zip")"

cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Meter</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Agent Meter $version</title>
      <link>https://github.com/$REPO/releases/tag/$tag</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$tag/$zip_name" type="application/octet-stream" $enclosure_attributes />
    </item>
  </channel>
</rss>
XML

if [[ "$publish" == false ]]; then
  echo "==> Built $zip (sha256 $sha256) and appcast.xml in $out; nothing was published."
  exit 0
fi

echo "==> Creating GitHub release $tag"
# Each release carries an appcast with just its own entry; Sparkle reads it through
# releases/latest/download/appcast.xml.
gh release create "$tag" \
  --repo "$REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "Agent Meter $version" \
  --generate-notes \
  "$zip" "$out/appcast.xml"

echo "==> Released $tag"
echo "The Homebrew cask is updated by the CI in scolor-dev/homebrew-tap (hourly, or run its workflow by hand)."
