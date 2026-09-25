#!/bin/bash
# Stages a Sparkle update of a built app in DIR — the zip and a one-item appcast pointing at it —
# and, for `publish`, releases both on GitHub, where the app's own feed looks.
# Signs with the login keychain's Sparkle key, or the key file in $SPARKLE_KEY_FILE.
# Usage: sparkle-release.sh dist|publish APP SPARKLE_BIN DIR
set -euo pipefail

mode=$1 app=$2 bin=$3 dir=$4
die() { echo "error: $*" >&2; exit 1; }
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }

[ "$mode" = dist ] || [ "$mode" = publish ] || die "unknown mode: $mode"
command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh"
[ -x "$bin/generate_appcast" ] || die "no $bin/generate_appcast: make release resolves Sparkle"

version=$(info CFBundleShortVersionString)
build=$(info CFBundleVersion)
feed=$(info SUFeedURL)
[ -n "$(info SUPublicEDKey)" ] ||
    die "no SUPublicEDKey: set SPARKLE_PUBLIC_KEY in project.yml (README, Publishing an update)"
repo=${feed#https://github.com/}
repo=${repo%/releases/latest/download/appcast.xml}
[ "https://github.com/$repo/releases/latest/download/appcast.xml" = "$feed" ] ||
    die "SUFeedURL is not a GitHub latest-release asset: '$feed'"
tag=v$version
sha=$(git rev-parse HEAD)

# TCC keys Accessibility and Input Monitoring to the signature, and an ad-hoc one is new every build.
signature=$(codesign -dv "$app" 2>&1) || die "$app is not signed"
case $signature in
    *Signature=adhoc*) die "$app is ad-hoc signed: every install would lose its grants on updating" ;;
esac

if [ "$mode" = publish ]; then
    [ -z "$(git status --porcelain)" ] || die "uncommitted changes: a release must build from its tag"
    main=$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)
    case $(gh api "repos/$repo/compare/$main...$sha" --jq .status) in
        behind | identical) ;;
        *) die "$sha is not on $repo's $main, the only branch whose build numbers keep growing" ;;
    esac
    ! gh api "repos/$repo/git/ref/tags/$tag" >/dev/null 2>&1 ||
        die "$tag exists: bump MARKETING_VERSION in project.yml"
    live=$(curl -fsSL "$feed" 2>/dev/null |
        sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' | head -1) || true
    [ -z "$live" ] || [ "$build" -gt "$live" ] ||
        die "build $build does not exceed the live feed's $live: installs would ignore it"
fi

rm -rf "$dir"
mkdir -p "$dir"
zip=$dir/mvim-$version.zip
notes=$dir/mvim-$version.md
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
gh api "repos/$repo/releases/generate-notes" -f tag_name="$tag" -f target_commitish="$sha" \
    --jq .body >"$notes" || die "GitHub wrote no release notes for $sha: is it pushed?"

appcast=(--download-url-prefix "https://github.com/$repo/releases/download/$tag/"
    --embed-release-notes --full-release-notes-url "https://github.com/$repo/releases"
    --link "https://github.com/$repo" -o "$dir/appcast.xml" "$dir")
[ -z "${SPARKLE_KEY_FILE:-}" ] || appcast=(--ed-key-file "$SPARKLE_KEY_FILE" "${appcast[@]}")
"$bin/generate_appcast" "${appcast[@]}"
# generate_appcast only warns when the key is not SUPublicEDKey's, and leaves the item unsigned.
grep -q 'sparkle:edSignature=' "$dir/appcast.xml" ||
    die "the update is unsigned: this signing key is not the one SUPublicEDKey names"

if [ "$mode" = dist ]; then
    echo "Staged mvim $version ($build) in $dir/ — make publish releases it as $tag."
    exit 0
fi

# gh uploads both assets before it publishes, so the feed never names a missing archive.
gh release create "$tag" "$zip" "$dir/appcast.xml" --repo "$repo" --target "$sha" \
    --title "mvim $version" --notes-file "$notes" --latest
echo "Released $tag: https://github.com/$repo/releases/tag/$tag"
