#!/usr/bin/env bash
# Dual-gateway differential suite for the Kuadrant -> PPE attribute mapping.
#
# For each case matching the glob it:
#   1. applies the Authorino AuthPolicy, waits for Enforced, fires requests at
#      the gateway (ground truth), then deletes the policy;
#   2. runs PPE with the mapped policy (cases/<stem>.ppe.yaml) and fires the
#      same logical requests locally;
#   3. runs PPE with the naive straight-translate (cases/<stem>.naive.yaml), if
#      present -- expected to diverge (documents issue #130);
#   4. prints a per-method matrix comparing expected / Authorino / PPE.
#
# Usage:
#   ./suite.sh                 # all cases
#   ./suite.sh 'cel-req-*'     # request-attribute CEL cases (glob on stem)
#
# Env knobs:
#   PRAXIS_AI_DIR   praxis-ai checkout (default ~/projects/.../ai)
#   SETTLE          seconds to wait after Enforced before firing (default 3)
#
# Kept compatible with bash 3.2 (macOS system bash): no associative arrays,
# no mapfile.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="${SCRIPT_DIR}/cases"
PRAXIS_AI_DIR="${PRAXIS_AI_DIR:-${HOME}/projects/src/github.com/praxis-proxy/ai}"
BIN="${PRAXIS_AI_DIR}/target/release/praxis-ai"
CONFIG="${SCRIPT_DIR}/praxis.yaml"
PPE_LOG="$(mktemp -t praxis-suite.XXXXXX)"

# Testbed coordinates (match testbed/*.yaml).
ROUTE_NS="toystore"
GW_NS="api-gateway"
GW_NAME="external"
HOST="api.toystore.com"
AUTHORINO_PATH="/toys"       # HTTPRoute matches this prefix
PPE_ADDR="127.0.0.1:8095"
PPE_PATH="/anything"         # httpbin serves any method here as 200
HTTPBIN="127.0.0.1:9200"
SETTLE="${SETTLE:-3}"

GLOB="${1:-*}"

PPE_PID=""
CUR_AUTHPOLICY=""   # file currently applied, for cleanup

cleanup() {
  [ -n "$PPE_PID" ] && kill "$PPE_PID" 2>/dev/null; wait "$PPE_PID" 2>/dev/null || true
  [ -n "$CUR_AUTHPOLICY" ] && kubectl delete -f "$CUR_AUTHPOLICY" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$PPE_LOG"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

code2dec() { case "$1" in 200) echo allow;; 403) echo deny;; 000) echo noconn;; *) echo "http$1";; esac; }

fire() { # url method [hosthdr] -> prints http code
  local url="$1" method="$2" host="${3:-}"
  if [ -n "$host" ]; then
    curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $host" -X "$method" "$url"
  else
    curl -s -o /dev/null -m 5 -w '%{http_code}' -X "$method" "$url"
  fi
}

start_ppe() { # policy-src-file -> 0 up / 1 failed
  cp "$1" "${SCRIPT_DIR}/policy-active.yaml"
  ( cd "$SCRIPT_DIR" && exec "$BIN" -c "$CONFIG" ) >"$PPE_LOG" 2>&1 &
  PPE_PID=$!
  local i
  for i in $(seq 1 50); do
    if grep -q 'is in use' "$PPE_LOG"; then echo "  port 8095 in use" >&2; return 1; fi
    kill -0 "$PPE_PID" 2>/dev/null || { echo "  PPE exited early:" >&2; tail -5 "$PPE_LOG" >&2; return 1; }
    if curl -s -o /dev/null -m 2 "http://${PPE_ADDR}/" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  echo "  PPE did not start listening" >&2; return 1
}

stop_ppe() {
  [ -n "$PPE_PID" ] && kill "$PPE_PID" 2>/dev/null; wait "$PPE_PID" 2>/dev/null || true
  PPE_PID=""
}

# --- preconditions -----------------------------------------------------------
[ -x "$BIN" ] || die "praxis-ai not found at $BIN (build: cd $PRAXIS_AI_DIR && make release)"
curl -s -o /dev/null -m 3 "http://${HTTPBIN}/anything" || die "httpbin not on ${HTTPBIN} (docker run -d --name httpbin -p 9200:80 kennethreitz/httpbin)"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (expect context kind-kuadrant-local)"
if lsof -ti tcp:8095 >/dev/null 2>&1; then die "127.0.0.1:8095 in use (pid $(lsof -ti tcp:8095 | tr '\n' ' ')) -- stop it first"; fi
GW="$(kubectl get gateway "$GW_NAME" -n "$GW_NS" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
[ -n "$GW" ] || die "gateway ${GW_NAME}/${GW_NS} has no address (is the testbed applied?)"
echo "gateway: $GW   settle: ${SETTLE}s"

# --- discover cases ----------------------------------------------------------
shopt -s nullglob
# Unquoted on purpose: GLOB must undergo pathname expansion. nullglob -> empty
# array when nothing matches. Case stems have no spaces.
POLICIES=( ${CASES_DIR}/${GLOB}.authpolicy.yaml )
shopt -u nullglob
[ ${#POLICIES[@]} -gt 0 ] || die "no cases matched: ${GLOB}.authpolicy.yaml"

compat_fail=0
truth_fail=0
ROWS=()   # table rows accumulated; printed once at the end so progress (stderr)
          # and the table (stdout) do not interleave.

progress() { echo "  $*" >&2; }

for ap in "${POLICIES[@]}"; do
  stem="$(basename "$ap" .authpolicy.yaml)"
  exp_file="${CASES_DIR}/${stem}.expected"
  ppe_file="${CASES_DIR}/${stem}.ppe.yaml"
  naive_file="${CASES_DIR}/${stem}.naive.yaml"
  [ -f "$exp_file" ] || { echo "SKIP $stem: no .expected"; continue; }
  echo "[$stem]" >&2

  # parse expected into parallel arrays
  methods=(); wants=()
  while read -r m d _; do
    [ -z "$m" ] && continue
    case "$m" in \#*) continue;; esac
    methods+=("$m"); wants+=("$d")
  done < "$exp_file"
  n=${#methods[@]}

  # 1) Authorino ground truth
  name="$(awk '/^metadata:/{m=1} m&&/name:/{print $2; exit}' "$ap")"; name="${name:-$stem}"
  CUR_AUTHPOLICY="$ap"
  kubectl apply -f "$ap" >/dev/null
  kubectl wait --for=condition=Enforced "authpolicy/${name}" -n "$ROUTE_NS" --timeout=60s >/dev/null 2>&1 \
    || echo "  warn: $name did not report Enforced within 60s" >&2
  # The Enforced condition tracks the CR; the istio filter lags it. Poll a known
  # deny-expected method until it is actually denied (filter live) before
  # measuring. This confirms the ground-truth baseline is real; it does not
  # touch PPE, so it cannot mask a PPE compat mismatch. Falls back to SETTLE if
  # the case has no deny method.
  probe_m=""
  for ((i=0; i<n; i++)); do [ "${wants[$i]}" = "deny" ] && { probe_m="${methods[$i]}"; break; }; done
  if [ -n "$probe_m" ]; then
    ready=0; waited=0
    for t in $(seq 1 30); do
      [ "$(fire "http://${GW}${AUTHORINO_PATH}" "$probe_m" "$HOST")" = "403" ] && { ready=1; waited=$t; break; }
      sleep 1
    done
    if [ "$ready" = "1" ]; then
      progress "✓ authpolicy enforced (${waited}s)"
    else
      progress "✗ authpolicy enforcement TIMEOUT (probe $probe_m != 403 after 30s)"
    fi
  else
    sleep "$SETTLE"
    progress "✓ authpolicy enforced (no deny method, settled ${SETTLE}s)"
  fi
  authz=()
  for ((i=0; i<n; i++)); do authz[$i]="$(code2dec "$(fire "http://${GW}${AUTHORINO_PATH}" "${methods[$i]}" "$HOST")")"; done
  kubectl delete -f "$ap" --ignore-not-found >/dev/null 2>&1
  CUR_AUTHPOLICY=""

  # 2) PPE mapped
  map=()
  if [ -f "$ppe_file" ] && start_ppe "$ppe_file"; then
    progress "✓ praxis (mapped) started"
    for ((i=0; i<n; i++)); do map[$i]="$(code2dec "$(fire "http://${PPE_ADDR}${PPE_PATH}" "${methods[$i]}")")"; done
    stop_ppe
  else
    [ -f "$ppe_file" ] && progress "✗ praxis (mapped) failed to start"
    for ((i=0; i<n; i++)); do map[$i]="-"; done
  fi

  # 3) PPE naive
  naive=()
  if [ -f "$naive_file" ] && start_ppe "$naive_file"; then
    progress "✓ praxis (naive) started"
    for ((i=0; i<n; i++)); do naive[$i]="$(code2dec "$(fire "http://${PPE_ADDR}${PPE_PATH}" "${methods[$i]}")")"; done
    stop_ppe
  else
    [ -f "$naive_file" ] && progress "✗ praxis (naive) failed to start"
    for ((i=0; i<n; i++)); do naive[$i]="-"; done
  fi

  # 4) rows (accumulated; table printed after the loop)
  for ((i=0; i<n; i++)); do
    m="${methods[$i]}"; exp="${wants[$i]}"; az="${authz[$i]}"; mp="${map[$i]}"; nv="${naive[$i]}"
    az_mark="ok"; [ "$az" != "$exp" ] && { az_mark="DIFF"; truth_fail=$((truth_fail+1)); }
    if [ "$mp" = "-" ]; then mp_cell="-"; elif [ "$mp" = "$az" ]; then mp_cell="${mp}(ok)"; else mp_cell="${mp}(DIFF)"; compat_fail=$((compat_fail+1)); fi
    if [ "$nv" = "-" ]; then nv_cell="-"; elif [ "$nv" = "$az" ]; then nv_cell="${nv}(match)"; else nv_cell="${nv}(#130)"; fi
    ROWS+=("$(printf '%-22s %-7s %-6s %-11s %-11s %-11s' "$stem" "$m" "$exp" "${az}(${az_mark})" "$mp_cell" "$nv_cell")")
  done
done

echo
printf '%-22s %-7s %-6s %-11s %-11s %-11s\n' CASE METHOD EXP AUTHORINO PPE-MAP PPE-NAIVE
printf '%s\n' "----------------------------------------------------------------------------"
[ ${#ROWS[@]} -gt 0 ] && for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
echo
echo "legend: AUTHORINO/PPE-MAP vs expected (ok/DIFF); PPE-NAIVE vs Authorino (match / #130 = expected divergence)."
echo "summary: ground-truth mismatches=${truth_fail}, PPE-mapped compat failures=${compat_fail}"
[ "$compat_fail" -eq 0 ] && [ "$truth_fail" -eq 0 ] || exit 1
