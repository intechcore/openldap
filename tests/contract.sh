#!/bin/bash
# Checks the configuration contract. Every environment variable in the table
# of the README section "Configuration" must appear in a test under tests/.
# tests/contract-allowlist.txt exempts variables that CI cannot test, one per
# line with a reason. Prints the uncovered variables and fails if any exist.
#
#   tests/contract.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
ALLOWLIST="$ROOT/tests/contract-allowlist.txt"

# Rows of the form: | `LDAP_DOMAIN` | default | description |
vars=$(awk '
    /^## / { in_section = ($0 == "## Configuration") ; next }
    in_section && /^\| `[A-Z][A-Z0-9_]*` \|/ { split($0, cell, "`"); print cell[2] }
' "$README")
if [[ -z "$vars" ]]; then
    echo "contract: no variables found in the Configuration table of README.md" >&2
    exit 2
fi

allowed() {
    local name="$1"
    [[ -f "$ALLOWLIST" ]] || return 1
    grep -qE "^${name}([[:space:]]|$)" "$ALLOWLIST"
    return $?
}

# A test mentions the variable as a whole word. Fixtures hold only LDIF data.
tested() {
    local name="$1"
    find "$ROOT/tests" -type f ! -path '*/fixtures/*' \
        ! -name contract.sh ! -name contract-allowlist.txt \
        -exec grep -qwF -- "$name" {} +
    return $?
}

total=0; covered=0; exempt=0; missing=""
for v in $vars; do
    total=$((total + 1))
    if tested "$v"; then
        covered=$((covered + 1))
    elif allowed "$v"; then
        exempt=$((exempt + 1))
    else
        missing="$missing $v"
    fi
done

# An allowlist entry must name a documented variable.
stale=""
if [[ -f "$ALLOWLIST" ]]; then
    while read -r a _; do
        [[ -z "$a" || "$a" == \#* ]] && continue
        echo "$vars" | grep -qx -- "$a" || stale="$stale $a"
    done < "$ALLOWLIST"
fi

echo "Configuration contract: $covered of $total variables tested, $exempt allowlisted"
for v in $missing; do echo "  not tested: $v"; done
for a in $stale; do echo "  allowlisted but not documented: $a"; done
[[ -z "$missing" && -z "$stale" ]]
