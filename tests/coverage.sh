#!/bin/bash
# Measures the line coverage of entrypoint.sh and reload-tls.sh. Runs the
# integration and migration tests against the coverage image, then merges the
# kcov data of all containers and processes.
#
#   tests/coverage.sh <coverage image> <output directory>
#
# Build the image with: docker build --target coverage -t <image> .
#
# The output directory gets coverage.xml (SonarQube generic format, with
# repository paths), coverage.json (the kcov summary) and html/ (the kcov
# report). A failed test fails the script, the report is still written.
set -euo pipefail

IMAGE=${1:?usage: tests/coverage.sh <coverage image> <output directory>}
OUT=${2:?usage: tests/coverage.sh <coverage image> <output directory>}
TESTS="$(cd "$(dirname "$0")" && pwd)/integration"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
KCOV="$(mktemp -d)"
# The containers run as root and write the kcov data as root.
# shellcheck disable=SC2329 # invoked by the trap
cleanup() {
    docker run --rm -v "$KCOV:/cov" --entrypoint sh "$IMAGE" -c 'rm -rf /cov/*' || true
    rmdir "$KCOV" || true
    return 0
}
trap cleanup EXIT

status=0
COVERAGE_DIR="$KCOV" "$TESTS/test-integration.sh" "$IMAGE" || status=1
COVERAGE_DIR="$KCOV" "$TESTS/test-migration.sh" "$IMAGE" || status=1

# The report names each script by its path in the image, /opt/coverage/<name>.
# The scripts sit at the repository root under the same name.
docker run --rm -v "$KCOV:/cov:ro" -v "$OUT:/out" --entrypoint sh \
    -e OWNER="$(id -u):$(id -g)" "$IMAGE" -c '
  set -e
  kcov --merge /tmp/merged /cov/*/
  sed "s|path=\"/opt/coverage/|path=\"|" /tmp/merged/kcov-merged/sonarqube.xml > /out/coverage.xml
  cp /tmp/merged/kcov-merged/coverage.json /out/coverage.json
  rm -rf /out/html
  cp -r /tmp/merged /out/html
  chown -R "$OWNER" /out'

echo ""
echo "=== Line coverage ==="
grep '"file"' "$OUT/coverage.json" |
    sed -E 's|.*"/opt/coverage/([^"]+)".*"percent_covered": "([^"]+)".*"covered_lines": "([^"]+)".*"total_lines": "([^"]+)".*|  \1: \2% (\3 of \4 lines)|'
exit "$status"
