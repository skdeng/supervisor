#!/bin/bash
# Cuts a SuperVisor release for Sparkle auto-update: stamps the version into Info.plist,
# builds and signs the bundle, zips it, EdDSA-signs the zip with the key in the login
# Keychain ("Private key for signing Sparkle updates"), prepends the appcast entry, commits
# and tags, and publishes — asset first, feed last: the tag and zip go up before the
# appcast lands on main, so the feed never points at a download that does not exist yet.
#
# The appcast is served from this repo's main branch (raw.githubusercontent.com); installed
# apps verify each zip against SUPublicEDKey plus the app's own code signature, so the
# hosts never need to be trusted.
#
# Recovery from a failure after the release commit: delete the local tag
# (`git tag -d v<version>`) and drop the commit (`git reset --hard HEAD~1`), then rerun.
# A failure before the commit restores the stamped files automatically.
#
# Usage:  ./release.sh <version> [release notes…]        e.g.  ./release.sh 1.0.1 "Fix X"
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [notes…]}"
shift || true
NOTES="${*:-SuperVisor ${VERSION}}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be semver (e.g. 1.2.3)" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "release from main (currently on $(git rev-parse --abbrev-ref HEAD))" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean — commit or stash first" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null \
  || git ls-remote --tags origin | grep -q "refs/tags/v${VERSION}\$"; then
  echo "tag v${VERSION} already exists (locally or on origin)" >&2
  exit 1
fi

# An update bundle must satisfy the installed app's designated requirement, so a release
# may only ever be signed with the Developer ID identity — make-app.sh's Apple Development
# and ad-hoc fallbacks would produce a zip every installed copy refuses to install.
security find-identity -v -p codesigning | grep -q "Developer ID Application:" \
  || { echo "no Developer ID Application identity in the keychain — cannot cut a release" >&2; exit 1; }

# sign_update ships in Sparkle's release archive, not the SPM artifact; cache it under
# build/ (gitignored), keyed by the version Package.resolved pins so a Sparkle bump
# refreshes the tools with it.
SPARKLE_VERSION="$(python3 -c "import json; print([p['state']['version'] for p in json.load(open('Package.resolved'))['pins'] if p['identity']=='sparkle'][0])")"
TOOLS="build/sparkle-tools/${SPARKLE_VERSION}/bin"
if [ ! -x "${TOOLS}/sign_update" ]; then
  echo "==> Fetching Sparkle ${SPARKLE_VERSION} signing tools…"
  mkdir -p "build/sparkle-tools/${SPARKLE_VERSION}"
  gh release download "$SPARKLE_VERSION" -R sparkle-project/Sparkle \
    -p "Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -O "build/sparkle-tools/${SPARKLE_VERSION}/sparkle.tar.xz" --clobber
  tar -xf "build/sparkle-tools/${SPARKLE_VERSION}/sparkle.tar.xz" \
    -C "build/sparkle-tools/${SPARKLE_VERSION}" bin/sign_update bin/generate_keys
fi

# A failure between here and the release commit leaves the tree clean.
trap 'git checkout -- Info.plist appcast.xml' ERR

echo "==> Stamping ${VERSION}…"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  -c "Set :CFBundleVersion ${VERSION}" \
  Info.plist

./make-app.sh --release

ZIP="build/SuperVisor-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent build/SuperVisor.app "$ZIP"

echo "==> Signing update…"
ENCLOSURE_ATTRS="$("${TOOLS}/sign_update" "$ZIP")"

echo "==> Updating appcast…"
python3 - "$VERSION" "$ENCLOSURE_ATTRS" "$NOTES" <<'PY'
import sys
from email.utils import formatdate

version, attrs, notes = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
path = "appcast.xml"
cast = open(path).read()
if f"<sparkle:version>{version}</sparkle:version>" in cast:
    sys.exit(f"appcast already carries {version}")

marker = "<!-- release.sh prepends items here; newest first -->"
if marker not in cast:
    sys.exit("appcast marker missing")

notes_cdata = notes.replace("]]>", "]]]]><![CDATA[>")
item = f"""{marker}
    <item>
      <title>{version}</title>
      <pubDate>{formatdate(localtime=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes_cdata}]]></description>
      <enclosure
        url="https://github.com/skdeng/supervisor/releases/download/v{version}/SuperVisor-{version}.zip"
        {attrs}
        type="application/octet-stream"/>
    </item>"""
open(path, "w").write(cast.replace(marker, item))
PY

# Package.resolved joins the commit in case the build refreshed it — a named-path add that
# missed it would leave the tree dirty and block the next release's clean-tree gate.
git add Info.plist appcast.xml Package.resolved
git commit -m "Release ${VERSION}"
trap - ERR
git tag "v${VERSION}"

git push origin "v${VERSION}"
echo "==> Publishing GitHub release…"
gh release create "v${VERSION}" "$ZIP" --title "SuperVisor ${VERSION}" --notes "$NOTES"
git push origin main

echo "==> Released ${VERSION} — installed apps pick it up on their next daily check."
