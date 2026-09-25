# Test-spike environment setup

Reproducible environment for the Kuadrant AuthPolicy → PPE differential
tests (issue #133). Two gateways evaluate the same predicate; requests are
fired at both and status codes compared:

- **Authorino** (ground truth) — a Kuadrant `AuthPolicy` on a live kind
  cluster.
- **PPE** — the `praxis-ai` proxy running the equivalent policy locally.

See `docs/proposals/00133_kuadrant-authpolicy-attribute-mapping.md` for what
is being proven.

## Prerequisites

- `docker` (or podman), `kind`, `kubectl`, `curl`
- Rust stable 1.92+ (to build `praxis-ai`)
- Repos cloned as siblings under your GOPATH-style tree:
  - `kuadrant-operator` (github.com/Kuadrant/kuadrant-operator)
  - `praxis-proxy/ai` (the `praxis-ai` proxy)
  - `praxis-proxy/policy` (this repo)

## Part A — Authorino ground-truth cluster

### 1. Create the cluster + install Kuadrant

```console
git clone https://github.com/Kuadrant/kuadrant-operator
cd kuadrant-operator
make local-setup
```

### 2. Activate the control plane (Kuadrant CR) and wait for ready

```console
kubectl apply -f <policy-repo>/test-spike/testbed/10-kuadrant-cr.yaml
kubectl -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=300s
```

### 3. Create namespaces, gateway, and route

The upstream `toystore.yaml` is **app-only** (Deployment + Service, no
namespace). The Gateway and HTTPRoute are not in it — apply ours:

```console
kubectl apply -f <policy-repo>/test-spike/testbed/00-namespaces.yaml
kubectl apply -f <policy-repo>/test-spike/testbed/20-gateway.yaml
kubectl apply -f <policy-repo>/test-spike/testbed/30-httproute.yaml
```

### 4. Deploy the toystore app (into the `toystore` namespace)

The HTTPRoute backendRef resolves to `Service/toystore` in the `toystore`
namespace, so the app must go there (not upstream's default):

```console
kubectl apply -n toystore -f \
  https://raw.githubusercontent.com/Kuadrant/kuadrant-operator/refs/heads/main/examples/toystore/toystore.yaml
kubectl -n toystore rollout status deploy/toystore --timeout=120s
```

### 5. Apply an AuthPolicy and verify

Apply one predicate from `test-spike/*.authpolicy.yaml`, e.g.:

```console
kubectl apply -f <policy-repo>/test-spike/cel-req-method.authpolicy.yaml
```

Find the gateway address and fire requests (host header routes to the
HTTPRoute):

```console
GW=$(kubectl get gateway external -n api-gateway \
  -o jsonpath='{.status.addresses[0].value}')

curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.toystore.com' -X POST   http://$GW/toys   # 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.toystore.com' -X GET    http://$GW/toys   # 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.toystore.com' -X DELETE http://$GW/toys   # 403
```

Swap the AuthPolicy (`kubectl apply` the next `*.authpolicy.yaml`), re-fire,
and walk the matrix.

## Part B — PPE side

### 6. Build the praxis-ai proxy

```console
git clone <praxis-ai repo>
cd ai
make release 
```

Produces the binary at `target/release/praxis-ai`. `test-spike/run.sh`
expects it there — edit `BIN` in `run.sh` if your checkout path differs.

### 7. Start a backend and run PPE

```console
docker run -d --name httpbin -p 9200:80 kennethreitz/httpbin
cd <policy-repo>/test-spike
./run.sh          # starts PPE on 127.0.0.1:8095
# ./run.sh -t     # validate config only
# ./run.sh -T     # dump effective config
```

Fire the same requests at PPE and compare to the Authorino result. The PPE
policy is path-agnostic (predicate is on `http.method`, route prefix is `/`),
so use an httpbin-served path — `/anything` echoes any method as 200. (The
Authorino side uses `/toys` only because its HTTPRoute matches that prefix;
httpbin has no `/toys` route and would 404 even when the policy allows.)

```console
curl -s -o /dev/null -w '%{http_code}\n' -X POST   http://127.0.0.1:8095/anything   # 200 (allowed -> httpbin)
curl -s -o /dev/null -w '%{http_code}\n' -X GET    http://127.0.0.1:8095/anything   # 403 (denied by policy)
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://127.0.0.1:8095/anything   # 403 (denied by policy)
```

### 8. Naive straight-translate (evidence for #130)

`policy-naive.yaml` copies the Kuadrant predicate verbatim
(`request.method == 'POST'`) with no dictionary mapping — the lift-and-shift
[#130](https://github.com/praxis-proxy/policy/issues/130) warns against. Run
it via the `PRAXIS_CONFIG` override (stop the correct-mapping proxy first —
both bind `127.0.0.1:8095`):

```console
PRAXIS_CONFIG=./praxis-naive.yaml ./run.sh
```

```console
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8095/anything   # 403  (MISMATCH: Authorino allows -> 200)
curl -s -o /dev/null -w '%{http_code}\n' -X GET  http://127.0.0.1:8095/anything   # 403
```

Both configs pass `./run.sh -t` (exit 0) — the failure is runtime-only. The
naive POST is denied because PPE's `request.*` is trace metadata, not the HTTP
request, so `request.method` never equals `POST`. Observed: it fails
**silently** (plain 403, no eval error/panic), i.e. fails closed. That is the
divergence motivating the #130 compatibility shim.

## Notes

- `praxis-ai` uses PPE's own `policy` filter (`policy-test.yaml`), not the
  gRPC `kuadrant` filter — this spike compares attribute *semantics*, not the
  Envoy/Authorino wire integration.
- The PPE policy is authorization-only (no `authentication:`, no plugins),
  mirroring the `toystore` AuthPolicy which has no auth rule.
- Gap-row attributes are expected to *fail* on PPE; those tests document the
  gap rather than assert compatibility.
