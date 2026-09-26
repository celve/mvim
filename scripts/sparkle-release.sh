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

# The HTTP status GitHub answers a GET with; empty when it could not be asked.
http_status() { { gh api --include "$1" 2>/dev/null || true; } | sed -n '1s|^HTTP/[0-9.]* \([0-9]*\).*|\1|p'; }

# Every install updates from the latest release: outnumber its build and keep its signing identity.
check_latest() {
    local latest previous key requirement
    latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name) || die "could not read $repo's latest release"
    live=$(mktemp -d)
    trap 'rm -rf "$live"' EXIT
    gh release download "$latest" --repo "$repo" --pattern appcast.xml --pattern 'mvim-*.zip' --dir "$live" ||
        die "could not download $latest's appcast.xml and zip"
    previous=$(sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' "$live/appcast.xml")
    previous=${previous%%$'\n'*}
    case $previous in '' | *[!0-9]*) die "$latest's appcast.xml names no numeric build" ;; esac
    [ "$build" -gt "$previous" ] || die "build $build does not exceed $latest's $previous: installs would ignore it"
    ditto -x -k "$live"/mvim-*.zip "$live/app"
    # Installs verify an update with the EdDSA key they shipped with, so a new one strands them all.
    key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$live/app/mvim.app/Contents/Info.plist") ||
        die "could not read the SUPublicEDKey of $latest's app"
    [ "$(info SUPublicEDKey)" = "$key" ] ||
        die "$app's SUPublicEDKey is not the one $latest shipped: every install would reject the update" \
            "(generate_keys -f imports the original private key)"
    requirement=$(codesign -d -r- "$live/app/mvim.app" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p')
    [ -n "$requirement" ] || die "could not read the designated requirement of $latest's app"
    # TCC holds each install's grants against that requirement, so an app failing it starts over.
    [ -n "${SPARKLE_NEW_IDENTITY:-}" ] || codesign --verify --test-requirement="=$requirement" "$app" ||
        die "$app does not satisfy $latest's designated requirement: every install would lose its grants" \
            "(SPARKLE_NEW_IDENTITY=1 publishes anyway)"
}

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
    case $(http_status "repos/$repo/git/ref/tags/$tag") in
        404) ;;
        200) die "$tag exists: bump MARKETING_VERSION in project.yml" ;;
        *) die "could not ask GitHub whether $tag exists" ;;
    esac
    case $(http_status "repos/$repo/releases/latest") in
        404) echo "No release yet: $tag will be the first." ;;
        200) check_latest ;;
        *) die "could not read $repo's latest release" ;;
    esac
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
