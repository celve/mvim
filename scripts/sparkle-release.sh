#!/bin/bash
# Notarizes a built app and stages its Sparkle update in DIR; `publish` also releases it on GitHub.
# Notarizes with the keychain profile $NOTARY_PROFILE names, made by `notarytool store-credentials`.
# Signs the update with the login keychain's Sparkle key, or the key file in $SPARKLE_KEY_FILE.
# Usage: sparkle-release.sh dist|publish APP SPARKLE_BIN DIR
set -euo pipefail

mode=$1 app=$2 bin=$3 dir=$4
name=$(basename "$app" .app)
die() { echo "error: $*" >&2; exit 1; }
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }

[ "$mode" = dist ] || [ "$mode" = publish ] || die "unknown mode: $mode"
command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh"
[ -x "$bin/generate_appcast" ] || die "no $bin/generate_appcast: make release resolves Sparkle"
[ -n "${NOTARY_PROFILE:-}" ] ||
    die "NOTARY_PROFILE names no notarytool keychain profile (README, Publishing an update)"

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
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The HTTP status GitHub answers a GET with; empty when it could not be asked.
http_status() { { gh api --include "$1" 2>/dev/null || true; } | sed -n '1s|^HTTP/[0-9.]* \([0-9]*\).*|\1|p'; }

# Every install updates from the latest release: outnumber its build and keep its signing identity.
check_latest() {
    local latest previous key requirement released live=$work/latest
    mkdir "$live"
    latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name) || die "could not read $repo's latest release"
    # Found by kind, not by name: the release before a rename carries the old one.
    gh release download "$latest" --repo "$repo" --pattern appcast.xml --pattern '*.zip' --dir "$live" ||
        die "could not download $latest's appcast.xml and zip"
    previous=$(sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' "$live/appcast.xml")
    previous=${previous%%$'\n'*}
    case $previous in '' | *[!0-9]*) die "$latest's appcast.xml names no numeric build" ;; esac
    [ "$build" -gt "$previous" ] || die "build $build does not exceed $latest's $previous: installs would ignore it"
    set -- "$live"/*.zip
    [ $# = 1 ] && [ -f "$1" ] || die "$latest does not hold exactly one zip"
    ditto -x -k "$1" "$live/app"
    set -- "$live"/app/*.app
    [ $# = 1 ] && [ -d "$1" ] || die "$latest's zip does not hold exactly one app"
    released=$1
    # Installs check an update against the EdDSA key they shipped with, so the key is held fixed.
    key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$released/Contents/Info.plist") ||
        die "could not read the SUPublicEDKey of $latest's app"
    [ "$(info SUPublicEDKey)" = "$key" ] ||
        die "$app's SUPublicEDKey is not the one $latest shipped, which installs check updates against" \
            "(generate_keys -f imports the original private key)"
    requirement=$(codesign -d -r- "$released" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p')
    [ -n "$requirement" ] || die "could not read the designated requirement of $latest's app"
    # TCC holds each install's grants against that requirement, so an app failing it starts over.
    [ -n "${SPARKLE_NEW_IDENTITY:-}" ] || codesign --verify --test-requirement="=$requirement" "$app" ||
        die "$app does not satisfy $latest's designated requirement: every install would lose its grants" \
            "(SPARKLE_NEW_IDENTITY=1 publishes anyway)"
}

# Trusts the service's own Accepted in notarytool's answer, never its exit status alone.
notarize() {
    local answer id status exited=0
    echo "Notarizing $(basename "$1"): waiting for the notary service's answer."
    answer=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) ||
        exited=$?
    id=$(plutil -extract id raw -o - - <<<"$answer" 2>/dev/null) || id=
    status=$(plutil -extract status raw -o - - <<<"$answer" 2>/dev/null) || status=
    [ "$exited" = 0 ] && [ "$status" = Accepted ] && return
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "the notary service did not accept $(basename "$1"): ${status:-no status}, notarytool exited $exited"
}

# Sparkle strips quarantine from an update it installs, so Gatekeeper never sees one: this stands in.
require_notarized() {
    local assessment
    xcrun stapler validate "$1" || die "the zipped app carries no notarization ticket"
    assessment=$(spctl --assess --type execute -vv "$1" 2>&1) &&
        [[ $assessment = *'source=Notarized Developer ID'* ]] ||
        die "Gatekeeper does not take the zipped app as a notarized Developer ID app: $assessment"
}

# Apple's marks on a Developer ID Application certificate and on the authority that issues it.
developer_id='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
developer_id+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
codesign --verify --deep --strict --test-requirement="=$developer_id" "$app" ||
    die "$app is not signed with a Developer ID Application certificate: the notary service takes no other"

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
zip=$dir/$name-$version.zip
notes=$dir/$name-$version.md
# What this version has to tell its users goes above GitHub's list of pull requests.
lead=$(dirname "$0")/../docs/release-notes/$version.md
[ ! -f "$lead" ] || { cat "$lead"; echo; } >"$notes"
gh api "repos/$repo/releases/generate-notes" -f tag_name="$tag" -f target_commitish="$sha" \
    --jq .body >>"$notes" || die "GitHub wrote no release notes for $sha: is it pushed?"

# The service takes an archive but only the app can carry its ticket, so the app is zipped twice.
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$name-$version.zip"
notarize "$work/$name-$version.zip"
xcrun stapler staple "$app" || die "could not staple the notarization ticket to $app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/stapled.zip"
ditto -x -k "$work/stapled.zip" "$work/shipped"
require_notarized "$work/shipped/$name.app"
mv "$work/stapled.zip" "$zip"

appcast=(--download-url-prefix "https://github.com/$repo/releases/download/$tag/"
    --embed-release-notes --full-release-notes-url "https://github.com/$repo/releases"
    --link "https://github.com/$repo" -o "$dir/appcast.xml" "$dir")
[ -z "${SPARKLE_KEY_FILE:-}" ] || appcast=(--ed-key-file "$SPARKLE_KEY_FILE" "${appcast[@]}")
"$bin/generate_appcast" "${appcast[@]}"
# generate_appcast only warns when the key is not SUPublicEDKey's, and leaves the item unsigned.
grep -q 'sparkle:edSignature=' "$dir/appcast.xml" ||
    die "the update is unsigned: this signing key is not the one SUPublicEDKey names"

if [ "$mode" = dist ]; then
    echo "Staged $name $version ($build) in $dir/ — make publish releases it as $tag."
    exit 0
fi

# gh uploads both assets before it publishes, so the feed never names a missing archive.
gh release create "$tag" "$zip" "$dir/appcast.xml" --repo "$repo" --target "$sha" \
    --title "$name $version" --notes-file "$notes" --latest
echo "Released $tag: https://github.com/$repo/releases/tag/$tag"
