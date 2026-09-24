#!/bin/sh
# Coverage image only. Replaces docker-entrypoint.sh and reload-tls, and runs
# the original script under kcov. Each process writes into its own directory
# below /cov, since several containers and processes share the mount.
# kcov records up to the final exec and writes its report when the traced
# process exits. Stop the container, a SIGKILL loses the report.
set -e

case "$(basename "$0")" in
    docker-entrypoint.sh) script=/opt/coverage/entrypoint.sh ;;
    reload-tls) script=/opt/coverage/reload-tls.sh ;;
    *) echo "kcov-run: unknown script $0" >&2; exit 1 ;;
esac

name="$(basename "$script" .sh)"
out="$(mktemp -d "/cov/${name}.$$.$(date +%s).XXXXXX")"
# kcov relays the output of the script through a pipe. Without line buffering
# the log lines reach docker logs only when kcov exits, or never.
exec stdbuf -oL kcov --bash-dont-parse-binary-dir --include-path=/opt/coverage \
    "$out" "$script" "$@"
