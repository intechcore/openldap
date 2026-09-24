#!/usr/bin/env bash
# Writes the notes of a GitHub release as Markdown to stdout. The summary comes
# from CHANGELOG.md, not from the git log:
#   1. REASON, when the weekly rebuild released the image, and the update
#      of the upstream version between PREV_TAG and TAG.
#   2. The "## [<TAG>]" section of the changelog, if the release has one.
#      Otherwise the entries of "## [Unreleased]" added since PREV_TAG.
#   3. A components table from the NAME=VALUE arguments.
#   4. The commits since PREV_TAG, collapsed below the summary.
#
#   release-notes.sh [NAME=VALUE ...]
#
# Environment:
#   TAG        the new release tag, for example v1.31.6-4
#   PREV_TAG   the previous release of the same series, empty for the first
#   REASON     why the rebuild released the image, empty for a manual release
#   CHANGELOG  the changelog file, default CHANGELOG.md
#   COMMITS    false leaves out the commit list, default true
#   PRODUCT    name of the upstream software, for example OpenLDAP. When the
#              version in TAG differs from PREV_TAG, the notes name the update.
set -euo pipefail

TAG=${TAG:?TAG is required}
PREV_TAG=${PREV_TAG:-}
REASON=${REASON:-}
CHANGELOG=${CHANGELOG:-CHANGELOG.md}
COMMITS=${COMMITS:-true}
PRODUCT=${PRODUCT:-}

# Prints one section of a Keep a Changelog file, without its heading.
# $1 is the version in the heading, for example Unreleased or 1.31.6-4.
section() {
    awk -v version="$1" '
        /^## / {
            inside = (index($0, "## [" version "]") == 1)
            next
        }
        inside { print }'
}

# Prints each entry of a section on one line: "<heading>\t<entry>". Lines of
# one entry are joined with \036, so an entry that wraps stays one record.
entries() {
    awk '
        function flush() {
            if (entry != "") print heading "\t" entry
            entry = ""
        }
        /^### / { flush(); heading = $0; next }
        /^- / { flush(); entry = $0; next }
        /^[[:space:]]*$/ { flush(); next }
        entry != "" { entry = entry "\036" $0 }
        END { flush() }'
}

# Prints the entries of the second file that the first file does not hold,
# grouped under their headings, in the order of the second file.
new_entries() {
    awk -F '\t' '
        FILENAME == ARGV[1] { seen[$2] = 1; next }
        !($2 in seen) {
            if ($1 != last) {
                if (last != "" || printed) print ""
                if ($1 != "") print $1
                last = $1
            }
            gsub("\036", "\n", $2)
            print $2
            printed = 1
        }' "$1" "$2"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

version=${TAG#v}
section "$version" < "$CHANGELOG" > "$tmp/release"
if grep -q '[^[:space:]]' "$tmp/release"; then
    # The maintainer cut the section of this release before it ran.
    entries < "$tmp/release" > "$tmp/new"
    : > "$tmp/old"
else
    section Unreleased < "$CHANGELOG" | entries > "$tmp/new"
    : > "$tmp/old"
    if [[ -n $PREV_TAG ]]; then
        git show "${PREV_TAG}:${CHANGELOG}" 2> /dev/null | section Unreleased | entries > "$tmp/old" || true
    fi
fi
new_entries "$tmp/old" "$tmp/new" > "$tmp/changes"

echo "## What changed"
echo ""
if [[ -n $REASON ]]; then
    echo "### Rebuild"
    # The rebuild joins its reasons into one line, each ends with a period.
    awk '{
        n = split($0, parts, /\. /)
        for (i = 1; i <= n; i++) print "- " parts[i] (i < n ? "." : "")
    }' <<< "$REASON"
    echo ""
fi
# Tags are <upstream version>-<build>, with or without a leading v.
upstream=${version%-*}
prev_upstream=${PREV_TAG#v}
prev_upstream=${prev_upstream%-*}
updated=false
if [[ -n $PRODUCT && -n $PREV_TAG && $upstream != "$prev_upstream" ]]; then
    updated=true
    echo "### Upstream"
    echo "- Moves ${PRODUCT} from ${prev_upstream} to ${upstream}."
    echo ""
fi
if [[ -s $tmp/changes ]]; then
    cat "$tmp/changes"
    echo ""
elif [[ -z $REASON && $updated == false ]]; then
    if [[ -n $PREV_TAG ]]; then
        echo "No change in the changelog since ${PREV_TAG}."
    else
        echo "First release."
    fi
    echo ""
fi

if [[ $# -gt 0 ]]; then
    echo "## Components"
    echo ""
    echo "| Component | Version |"
    echo "|---|---|"
    for row in "$@"; do
        echo "| ${row%%=*} | \`${row#*=}\` |"
    done
    echo ""
fi

if [[ $COMMITS == true && -n $PREV_TAG ]]; then
    git log --pretty=tformat:'- %s (%h)' "${PREV_TAG}..HEAD" > "$tmp/commits"
    if [[ -s $tmp/commits ]]; then
        echo "<details>"
        echo "<summary>Commits since ${PREV_TAG}</summary>"
        echo ""
        cat "$tmp/commits"
        echo ""
        echo "</details>"
    fi
fi
