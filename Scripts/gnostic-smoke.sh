#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gnostic_package=${GNOSTIC_PACKAGE_PATH:-$repo_root/.build/SourcePackages/checkouts/Gnostic}
gnostic_config=${GNOSTIC_CONFIG:-$HOME/.gnostic/config.json}
host=${YAKAMOZ_GNOSTIC_HOST:-127.0.0.1}
port=${YAKAMOZ_GNOSTIC_PORT:-1883}
namespace=${YAKAMOZ_GNOSTIC_NAMESPACE:-yakamoz-smoke}
startup_timeout=${YAKAMOZ_GNOSTIC_STARTUP_TIMEOUT:-300}

die() {
    printf 'gnostic-smoke: %s\n' "$1" >&2
    exit 1
}

command -v swift >/dev/null 2>&1 || die "swift was not found"
test -d "$gnostic_package" || die "Gnostic checkout not found at $gnostic_package; run make generate first"
test -f "$gnostic_config" || die "Gnostic config not found at $gnostic_config; set GNOSTIC_CONFIG or run gnostic config init"

printf 'Checking broker %s:%s...\n' "$host" "$port"
if command -v mosquitto_pub >/dev/null 2>&1; then
    mosquitto_pub -h "$host" -p "$port" -t "$namespace/yakamoz-smoke/probe" -m ready
elif command -v nix-shell >/dev/null 2>&1; then
    nix-shell -p mosquitto --run "mosquitto_pub -h '$host' -p '$port' -t '$namespace/yakamoz-smoke/probe' -m ready"
else
    die "mosquitto_pub was not found; install Mosquitto or run through nix-shell -p mosquitto"
fi

printf 'Building Gnostic CLI...\n'
gnostic_bin=$(swift build --package-path "$gnostic_package" --configuration debug --product gnostic --show-bin-path)/gnostic
test -x "$gnostic_bin" || die "Gnostic CLI was not built at $gnostic_bin"

serve_log=${YAKAMOZ_SMOKE_LOG:-/tmp/yakamoz-gnostic-serve-$$.log}
serve_pid=""
preserve_log=0
cleanup() {
    if [[ -n "$serve_pid" ]]; then
        kill "$serve_pid" >/dev/null 2>&1 || true
        wait "$serve_pid" >/dev/null 2>&1 || true
    fi
    if [[ "$preserve_log" == 0 ]]; then
        rm -f "$serve_log"
    fi
}
trap cleanup EXIT INT TERM

"$gnostic_bin" serve \
    --config "$gnostic_config" \
    --host "$host" \
    --port "$port" \
    --namespace "$namespace" \
    --approve-mode auto \
    >"$serve_log" 2>&1 &
serve_pid=$!

ready=0
for ((second = 0; second < startup_timeout; second += 1)); do
    if grep -E "gnostic serve online at|advertised objects" "$serve_log" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$serve_pid" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then
    preserve_log=1
    printf 'gnostic-smoke: Gnostic serve did not become ready.\n' >&2
    printf 'gnostic-smoke: inspect %s for the local serve diagnostic.\n' "$serve_log" >&2
    exit 1
fi

cd "$repo_root"
if ! YAKAMOZ_GNOSTIC_SMOKE=1 \
    YAKAMOZ_GNOSTIC_HOST="$host" \
    YAKAMOZ_GNOSTIC_PORT="$port" \
    YAKAMOZ_GNOSTIC_NAMESPACE="$namespace" \
    YAKAMOZ_SMOKE_TOOL_ID="${YAKAMOZ_SMOKE_TOOL_ID:-workspace_echo}" \
    make test TEST_SCHEME=YakamozGnosticSmoke TEST_FILTER=GnosticLiveSmokeTests; then
    preserve_log=1
    printf 'gnostic-smoke: live test failed; inspect %s for the Node diagnostic.\n' "$serve_log" >&2
    exit 1
fi

printf 'Gnostic live smoke passed.\n'
