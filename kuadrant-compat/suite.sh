#!/usr/bin/env bash
# Compare one verbatim request.id predicate across Authorino and PPE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${SCRIPT_DIR}/cases/cel-req-id.ppe.yaml"
AUTH_POLICY="${SCRIPT_DIR}/cases/cel-req-id.authpolicy.yaml"
EXPECTED="${SCRIPT_DIR}/cases/cel-req-id.expected"
ACTIVE="${SCRIPT_DIR}/policy-active.yaml"
PRAXIS_AI_DIR="${PRAXIS_AI_DIR:-${HOME}/projects/src/github.com/praxis-proxy/ai}"
BIN="${PRAXIS_AI_DIR}/target/release/praxis-ai"
PPE_LOG="$(mktemp -t praxis-req-id.XXXXXX)"
PPE_PID=""
AUTH_APPLIED=""

stop_ppe() {
  if [ -n "$PPE_PID" ]; then
    kill "$PPE_PID" 2>/dev/null || true
    wait "$PPE_PID" 2>/dev/null || true
    PPE_PID=""
  fi
}

cleanup() {
  local status=$?
  stop_ppe
  if [ -n "$AUTH_APPLIED" ]; then
    kubectl delete -f "$AUTH_POLICY" --ignore-not-found >/dev/null 2>&1 || true
  fi
  rm -f "$ACTIVE"
  if [ "$status" -ne 0 ] && [ -s "$PPE_LOG" ]; then
    echo "PPE startup log: $PPE_LOG" >&2
  else
    rm -f "$PPE_LOG"
  fi
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

decision() {
  case "$1" in
    200) echo allow ;;
    403) echo deny ;;
    000) echo noconn ;;
    *) echo "http$1" ;;
  esac
}

fire() { # url host request-id -> HTTP status
  local url="$1" host="$2" request_id="$3"
  if [ -n "$host" ]; then
    curl -q -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $host" \
      -H "x-request-id: $request_id" "$url" || true
  else
    curl -q -s -o /dev/null -m 5 -w '%{http_code}' \
      -H "x-request-id: $request_id" "$url" || true
  fi
}

start_ppe() { # kuadrant_compat: false|true
  local compat="$1" started=$SECONDS status
  if [ "$compat" = true ]; then
    sed 's/^  kuadrant_compat: false$/  kuadrant_compat: true/' "$POLICY" > "$ACTIVE"
  else
    cp "$POLICY" "$ACTIVE"
  fi
  ( cd "$SCRIPT_DIR" && exec "$BIN" -c "${SCRIPT_DIR}/praxis.yaml" ) >"$PPE_LOG" 2>&1 &
  PPE_PID=$!
  while [ $((SECONDS - started)) -lt 60 ]; do
    if ! kill -0 "$PPE_PID" 2>/dev/null; then
      tail -30 "$PPE_LOG" >&2
      die "PPE exited before listening (kuadrant_compat=$compat)"
    fi
    status="$(fire http://127.0.0.1:8095/ "" req-abc)"
    if [ "$status" != 000 ]; then return 0; fi
    sleep 0.2
  done
  tail -30 "$PPE_LOG" >&2
  die "PPE did not start listening (kuadrant_compat=$compat)"
}

[ -x "$BIN" ] || die "praxis-ai not found at $BIN (see SETUP.md)"
[ "$(grep -cx '  kuadrant_compat: false' "$POLICY")" -eq 1 ] \
  || die "PPE policy must contain one kuadrant_compat: false line"
curl -q -s -o /dev/null -m 3 http://127.0.0.1:9200/anything \
  || die "httpbin is not reachable on 127.0.0.1:9200"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the testbed cluster"
if lsof -ti tcp:8095 >/dev/null 2>&1; then die "PPE port 8095 is in use"; fi
GW="$(kubectl get gateway external -n api-gateway -o jsonpath='{.status.addresses[0].value}')"
[ -n "$GW" ] || die "gateway api-gateway/external has no address"

ids=()
wants=()
while read -r request_id expected _; do
  [ -z "$request_id" ] && continue
  case "$request_id" in \#*) continue ;; esac
  ids+=("$request_id")
  wants+=("$expected")
done < "$EXPECTED"
[ "${#ids[@]}" -gt 0 ] || die "no expected decisions in $EXPECTED"

echo "gateway: $GW"
AUTH_APPLIED=1
kubectl apply -f "$AUTH_POLICY" >/dev/null
kubectl wait --for=condition=Enforced authpolicy/cel-req-id -n toystore --timeout=60s >/dev/null

# Wait for the gateway filter to catch up with the AuthPolicy condition.
for i in $(seq 1 30); do
  [ "$(fire "http://${GW}/toys" api.toystore.com req-abc)" = 200 ] && \
    [ "$(fire "http://${GW}/toys" api.toystore.com other)" = 200 ] && break
  sleep 1
done

authorino=()
for i in "${!ids[@]}"; do
  authorino+=("$(decision "$(fire "http://${GW}/toys" api.toystore.com "${ids[$i]}")")")
done
kubectl delete -f "$AUTH_POLICY" --ignore-not-found >/dev/null
AUTH_APPLIED=""

start_ppe false
off=()
for i in "${!ids[@]}"; do
  off+=("$(decision "$(fire http://127.0.0.1:8095/anything "" "${ids[$i]}")")")
done
stop_ppe

start_ppe true
on=()
for i in "${!ids[@]}"; do
  on+=("$(decision "$(fire http://127.0.0.1:8095/anything "" "${ids[$i]}")")")
done
stop_ppe

echo
printf '%-15s %-10s %-11s %-9s %-7s\n' REQUEST-ID EXPECTED AUTHORINO FLAG-OFF FLAG-ON
fail=0
for i in "${!ids[@]}"; do
  printf '%-15s %-10s %-11s %-9s %-7s\n' \
    "${ids[$i]}" "${wants[$i]}" "${authorino[$i]}" "${off[$i]}" "${on[$i]}"
  [ "${authorino[$i]}" = "${wants[$i]}" ] || fail=1
  [ "${off[$i]}" = deny ] || fail=1
  [ "${on[$i]}" = "${wants[$i]}" ] || fail=1
done
echo
[ "$fail" -eq 0 ] || die "request.id comparison failed"
echo "PASS: verbatim request.id resolves only with kuadrant_compat enabled"
