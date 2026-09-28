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
#   4. runs PPE with the SAME naive policy text plus engine_settings.kuadrant_compat:
#      true (issue #130 Approach A). This is the verbatim-Kuadrant arm: the compat
#      pass re-keys the bag to the WKA vocabulary, so the unmodified predicate now
#      resolves and should MATCH Authorino where the naive arm diverged.
#   5. prints a per-method matrix comparing expected / Authorino / PPE.
#
# The compat arm is synthesised from cases/<stem>.naive.yaml at run time (the
# kuadrant_compat flag is injected under engine_settings); there is no separate
# .compat.yaml file, so the compat and naive arms are guaranteed to run identical
# policy text -- the flag is the only variable.
#
# Two kinds of case:
#   * method case  — the .expected keys are HTTP methods; the request varies by
#                    method (GET/POST/DELETE).
#   * identity case — the case has a cases/<stem>.tokens file; the .expected keys
#                    name tokens. Each key mints a JWT (mock POST /generate) that
#                    is fired as Bearer on a GET; the identity varies, not the
#                    method. Needs testbed/40-mock-jwt.yaml applied; suite.sh
#                    port-forwards the mock to loopback automatically.
#
# Usage:
#   ./suite.sh                 # all cases
#   ./suite.sh 'cel-req-*'     # request-attribute CEL cases (glob on stem)
#   ./suite.sh 'cel-id-*'      # identity CEL cases
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

# Mock OIDC token minter for identity cases (testbed/40-mock-jwt.yaml). Runs
# in-cluster; reached locally via kubectl port-forward (see ensure_mock). One
# instance serves both vantage points because its keypair is per-boot.
MOCK_NS="toystore"
MOCK_SVC="mock-jwt"
MOCK_PORT="8088"
MOCK_ADDR="127.0.0.1:${MOCK_PORT}"

GLOB="${1:-*}"

PPE_PID=""
PFWD_PID=""         # kubectl port-forward to the mock, if started
CUR_AUTHPOLICY=""   # file currently applied, for cleanup

cleanup() {
  [ -n "$PPE_PID" ] && kill "$PPE_PID" 2>/dev/null; wait "$PPE_PID" 2>/dev/null || true
  [ -n "$PFWD_PID" ] && kill "$PFWD_PID" 2>/dev/null; wait "$PFWD_PID" 2>/dev/null || true
  [ -n "$CUR_AUTHPOLICY" ] && kubectl delete -f "$CUR_AUTHPOLICY" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$PPE_LOG"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

code2dec() { case "$1" in 200) echo allow;; 403) echo deny;; 000) echo noconn;; *) echo "http$1";; esac; }

fire() { # url method [hosthdr] [bearer] -> prints http code
  local url="$1" method="$2" host="${3:-}" bearer="${4:-}"
  local args=(-s -o /dev/null -m 5 -w '%{http_code}' -X "$method")
  [ -n "$host" ] && args+=(-H "Host: $host")
  [ -n "$bearer" ] && args+=(-H "Authorization: Bearer $bearer")
  curl "${args[@]}" "$url"
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

# --- identity-case support ---------------------------------------------------
# A case with a cases/<stem>.tokens file is an IDENTITY case: the .expected keys
# name tokens (not HTTP methods). ensure_mock brings up a port-forward to the
# in-cluster mock so both minting and PPE's JWKS fetch reach it on loopback.
ensure_mock() { # 0 reachable / 1 not
  curl -s -o /dev/null -m 2 "http://${MOCK_ADDR}/jwks" 2>/dev/null && return 0
  kubectl port-forward -n "$MOCK_NS" "svc/${MOCK_SVC}" "${MOCK_PORT}:${MOCK_PORT}" >/dev/null 2>&1 &
  PFWD_PID=$!
  local i
  for i in $(seq 1 25); do
    curl -s -o /dev/null -m 2 "http://${MOCK_ADDR}/jwks" 2>/dev/null && return 0
    kill -0 "$PFWD_PID" 2>/dev/null || { PFWD_PID=""; return 1; }
    sleep 0.4
  done
  return 1
}

mint() { # claims-json -> token (empty on failure)
  curl -s -m 5 -X POST "http://${MOCK_ADDR}/generate" \
    -H 'content-type: application/json' -d "$1"
}

# Per-case globals set in the loop; these helpers read them at call time.
MODE="method"       # "method" or "id"
ckeys=(); cvals=()  # token-key -> claims-json (id mode only)

claims_for() { # token-key -> claims-json
  local want="$1" i
  for ((i=0; i<${#ckeys[@]}; i++)); do
    [ "${ckeys[$i]}" = "$want" ] && { printf '%s' "${cvals[$i]}"; return; }
  done
}

fire_key() { # idx base_url [host] -> http code
  local idx="$1"
  local base="$2"
  local host="${3:-}"
  local key="${methods[$idx]}"
  if [ "$MODE" = "id" ]; then
    local tok; tok="$(mint "$(claims_for "$key")")"
    [ -z "$tok" ] && { echo "000"; return; }
    fire "$base" "GET" "$host" "$tok"   # identity varies; method fixed to GET
  else
    fire "$base" "$key" "$host"          # key IS the HTTP method
  fi
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
kc_fail=0   # kuadrant-compat arm mismatches vs Authorino (real feature failures)
ROWS=()   # table rows accumulated; printed once at the end so progress (stderr)
          # and the table (stdout) do not interleave.

progress() { echo "  $*" >&2; }

for ap in "${POLICIES[@]}"; do
  stem="$(basename "$ap" .authpolicy.yaml)"
  exp_file="${CASES_DIR}/${stem}.expected"
  ppe_file="${CASES_DIR}/${stem}.ppe.yaml"
  naive_file="${CASES_DIR}/${stem}.naive.yaml"
  tokens_file="${CASES_DIR}/${stem}.tokens"
  [ -f "$exp_file" ] || { echo "SKIP $stem: no .expected"; continue; }
  echo "[$stem]" >&2

  # parse expected into parallel arrays (methods[] holds the row KEY: an HTTP
  # method for method cases, a token name for identity cases)
  methods=(); wants=()
  while read -r m d _; do
    [ -z "$m" ] && continue
    case "$m" in \#*) continue;; esac
    methods+=("$m"); wants+=("$d")
  done < "$exp_file"
  n=${#methods[@]}

  # identity case? load the token claim sets and bring up the mock
  MODE="method"; ckeys=(); cvals=()
  if [ -f "$tokens_file" ]; then
    MODE="id"
    while read -r k rest; do
      [ -z "$k" ] && continue
      case "$k" in \#*) continue;; esac
      ckeys+=("$k"); cvals+=("$rest")
    done < "$tokens_file"
    if ! ensure_mock; then
      progress "✗ mock-jwt not reachable on ${MOCK_ADDR} (is testbed/40-mock-jwt.yaml applied?) — skipping $stem"
      continue
    fi
    progress "✓ mock-jwt reachable (${MOCK_ADDR})"
  fi

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
  probe_idx=-1
  for ((i=0; i<n; i++)); do [ "${wants[$i]}" = "deny" ] && { probe_idx=$i; break; }; done
  if [ "$probe_idx" -ge 0 ]; then
    ready=0; waited=0
    for t in $(seq 1 30); do
      [ "$(fire_key "$probe_idx" "http://${GW}${AUTHORINO_PATH}" "$HOST")" = "403" ] && { ready=1; waited=$t; break; }
      sleep 1
    done
    if [ "$ready" = "1" ]; then
      progress "✓ authpolicy enforced (${waited}s)"
    else
      progress "✗ authpolicy enforcement TIMEOUT (probe ${methods[$probe_idx]} != 403 after 30s)"
    fi
  else
    sleep "$SETTLE"
    progress "✓ authpolicy enforced (no deny key, settled ${SETTLE}s)"
  fi
  authz=()
  for ((i=0; i<n; i++)); do authz[$i]="$(code2dec "$(fire_key "$i" "http://${GW}${AUTHORINO_PATH}" "$HOST")")"; done
  kubectl delete -f "$ap" --ignore-not-found >/dev/null 2>&1
  CUR_AUTHPOLICY=""

  # 2) PPE mapped
  map=()
  if [ -f "$ppe_file" ] && start_ppe "$ppe_file"; then
    progress "✓ praxis (mapped) started"
    for ((i=0; i<n; i++)); do map[$i]="$(code2dec "$(fire_key "$i" "http://${PPE_ADDR}${PPE_PATH}")")"; done
    stop_ppe
  else
    [ -f "$ppe_file" ] && progress "✗ praxis (mapped) failed to start"
    for ((i=0; i<n; i++)); do map[$i]="-"; done
  fi

  # 3) PPE naive
  naive=()
  if [ -f "$naive_file" ] && start_ppe "$naive_file"; then
    progress "✓ praxis (naive) started"
    for ((i=0; i<n; i++)); do naive[$i]="$(code2dec "$(fire_key "$i" "http://${PPE_ADDR}${PPE_PATH}")")"; done
    stop_ppe
  else
    [ -f "$naive_file" ] && progress "✗ praxis (naive) failed to start"
    for ((i=0; i<n; i++)); do naive[$i]="-"; done
  fi

  # 4) PPE compat: the SAME verbatim policy as the naive arm, but with
  #    engine_settings.kuadrant_compat: true injected. The compat pass re-keys the
  #    bag into the Kuadrant WKA vocabulary, so the unmodified predicate resolves.
  #    Expected to MATCH Authorino where the naive arm shows #130.
  compat=()
  if [ -f "$naive_file" ]; then
    compat_src="$(mktemp -t praxis-compat.XXXXXX)"
    # Insert the flag right after the top-level `engine_settings:` line. Order of
    # keys under the map is irrelevant to YAML, so this is structure-independent.
    awk '{print} /^engine_settings:[[:space:]]*$/{print "  kuadrant_compat: true"}' \
      "$naive_file" > "$compat_src"
    if start_ppe "$compat_src"; then
      progress "✓ praxis (compat) started"
      for ((i=0; i<n; i++)); do compat[$i]="$(code2dec "$(fire_key "$i" "http://${PPE_ADDR}${PPE_PATH}")")"; done
      stop_ppe
    else
      progress "✗ praxis (compat) failed to start"
      for ((i=0; i<n; i++)); do compat[$i]="-"; done
    fi
    rm -f "$compat_src"
  else
    for ((i=0; i<n; i++)); do compat[$i]="-"; done
  fi

  # 5) rows (accumulated; table printed after the loop)
  for ((i=0; i<n; i++)); do
    m="${methods[$i]}"; exp="${wants[$i]}"; az="${authz[$i]}"; mp="${map[$i]}"; nv="${naive[$i]}"; kc="${compat[$i]}"
    az_mark="ok"; [ "$az" != "$exp" ] && { az_mark="DIFF"; truth_fail=$((truth_fail+1)); }
    if [ "$mp" = "-" ]; then mp_cell="-"; elif [ "$mp" = "$az" ]; then mp_cell="${mp}(ok)"; else mp_cell="${mp}(DIFF)"; compat_fail=$((compat_fail+1)); fi
    if [ "$nv" = "-" ]; then nv_cell="-"; elif [ "$nv" = "$az" ]; then nv_cell="${nv}(match)"; else nv_cell="${nv}(#130)"; fi
    # Compat arm is a real feature check: it must MATCH Authorino (the naive text
    # now resolves via the WKA aliases). A mismatch is a compat-mode failure.
    if [ "$kc" = "-" ]; then kc_cell="-"; elif [ "$kc" = "$az" ]; then kc_cell="${kc}(ok)"; else kc_cell="${kc}(FAIL)"; kc_fail=$((kc_fail+1)); fi
    ROWS+=("$(printf '%-22s %-7s %-6s %-11s %-11s %-11s %-11s' "$stem" "$m" "$exp" "${az}(${az_mark})" "$mp_cell" "$nv_cell" "$kc_cell")")
  done
done

echo
printf '%-22s %-7s %-6s %-11s %-11s %-11s %-11s\n' CASE KEY EXP AUTHORINO PPE-MAP PPE-NAIVE PPE-COMPAT
printf '%s\n' "----------------------------------------------------------------------------------------"
[ ${#ROWS[@]} -gt 0 ] && for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
echo
echo "legend: AUTHORINO/PPE-MAP vs expected (ok/DIFF); PPE-NAIVE vs Authorino (match / #130 = expected divergence);"
echo "        PPE-COMPAT vs Authorino (ok = verbatim Kuadrant policy resolved under kuadrant_compat / FAIL = did not)."
echo "summary: ground-truth mismatches=${truth_fail}, PPE-mapped failures=${compat_fail}, PPE-compat failures=${kc_fail}"
[ "$compat_fail" -eq 0 ] && [ "$truth_fail" -eq 0 ] && [ "$kc_fail" -eq 0 ] || exit 1
