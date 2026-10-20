#!/bin/sh
# Publishes a release: tags v<version>, waits for the Release workflow to build and upload the app,
# then points the Homebrew cask in harsh-gulhane/homebrew-tap at it. Uses your `gh` login.
#
#   1. Set VERSION and add a "## [<version>]" section to CHANGELOG.md, and merge that to main
#      through a pull request (main is protected).
#   2. On an up-to-date main: scripts/release.sh <version>
set -eu

version=${1:?usage: scripts/release.sh <version>}
root=$(cd "$(dirname "$0")/.." && pwd)
repo=harsh-gulhane/logicam-tuner
tap=harsh-gulhane/homebrew-tap
cd "$root"

fail() { echo "release: $*" >&2; exit 1; }
[ "$(cat VERSION)" = "$version" ] || fail "VERSION is $(cat VERSION), not $version"
grep -q "^## \[$version\]" CHANGELOG.md || fail "CHANGELOG.md has no ## [$version] section"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "not on main"
git diff --quiet && git diff --cached --quiet || fail "commit your changes first"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "local main differs from origin/main: merge the release pull request, then git pull"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists"

git tag -a "v$version" -m "LogiCam Tuner $version"
git push origin "v$version"

echo "waiting for the Release workflow…"
run=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  run=$(gh run list -R "$repo" --workflow Release --branch "v$version" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || fail "the Release workflow did not start"
gh run watch "$run" -R "$repo" --exit-status

sha=$(gh release download "v$version" -R "$repo" --pattern '*.zip.sha256' --output - | tr -d '[:space:]')
[ ${#sha} -eq 64 ] || fail "could not read the release checksum"

work=$(mktemp -d)
gh repo clone "$tap" "$work" -- -q
cask="$work/Casks/logicam-tuner.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
git -C "$work" commit -qam "logicam-tuner $version"
git -C "$work" push -q
rm -rf "$work"
echo "released $version: https://github.com/$repo/releases/tag/v$version"
