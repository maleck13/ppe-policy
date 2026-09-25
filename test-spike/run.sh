#!/usr/bin/env bash
# Run praxis-ai with a single case's PPE policy (interactive inner loop).
# For batch dual-gateway comparison use suite.sh instead.
#
# Usage:
#   ./run.sh <case>              # start PPE with cases/<case>.ppe.yaml
#   ./run.sh <case> naive        # start PPE with cases/<case>.naive.yaml (#130)
#   ./run.sh <case> [naive] -t   # validate config and exit
#   ./run.sh <case> [naive] -T   # dump effective config and exit
#
# The selected policy is copied to ./policy-active.yaml (gitignored), which
# praxis.yaml loads. PPE listens on 127.0.0.1:8095.
#
# Override the praxis-ai checkout if yours differs:
#   PRAXIS_AI_DIR=/path/to/ai ./run.sh <case>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAXIS_AI_DIR="${PRAXIS_AI_DIR:-${HOME}/projects/src/github.com/praxis-proxy/ai}"
BIN="${PRAXIS_AI_DIR}/target/release/praxis-ai"
CONFIG="${SCRIPT_DIR}/praxis.yaml"

CASE="${1:-}"
if [[ -z "$CASE" ]]; then
  echo "usage: ./run.sh <case> [naive] [praxis-args...]" >&2
  echo "cases:" >&2
  ls -1 "${SCRIPT_DIR}/cases/"*.ppe.yaml 2>/dev/null | sed 's#.*/##; s/\.ppe\.yaml$//; s/^/  /' >&2 || true
  exit 2
fi
shift

VARIANT="ppe"
if [[ "${1:-}" == "naive" ]]; then VARIANT="naive"; shift; fi

SRC="${SCRIPT_DIR}/cases/${CASE}.${VARIANT}.yaml"
if [[ ! -f "$SRC" ]]; then
  echo "policy not found: $SRC" >&2
  exit 2
fi

if [[ ! -x "$BIN" ]]; then
  echo "praxis-ai binary not found at: $BIN" >&2
  echo "Build it: (cd \"$PRAXIS_AI_DIR\" && make release)" >&2
  echo "Or point PRAXIS_AI_DIR at your checkout." >&2
  exit 1
fi

# Refuse to start if the listener port is already taken (avoids hitting a stale
# proxy and mis-reading its decisions).
if lsof -ti tcp:8095 >/dev/null 2>&1; then
  echo "127.0.0.1:8095 is already in use (pid $(lsof -ti tcp:8095 | tr '\n' ' '))." >&2
  echo "Stop the other proxy first." >&2
  exit 1
fi

# Identity cases fetch a JWKS at PPE startup. If the mock isn't reachable on
# loopback the plugin fails to initialize (on_error: fail). Port-forward it.
if [[ -f "${SCRIPT_DIR}/cases/${CASE}.tokens" ]]; then
  if ! curl -s -o /dev/null -m 2 "http://127.0.0.1:8088/jwks" 2>/dev/null; then
    echo "warn: identity case but mock JWKS not reachable on 127.0.0.1:8088." >&2
    echo "      run: kubectl port-forward -n toystore svc/mock-jwt 8088:8088 &" >&2
  fi
fi

cp "$SRC" "${SCRIPT_DIR}/policy-active.yaml"
echo "active policy: cases/${CASE}.${VARIANT}.yaml" >&2
cd "$SCRIPT_DIR"
exec "$BIN" -c "$CONFIG" "$@"
