# Test-spike environment

Stands up the two gateways for the Kuadrant AuthPolicy → PPE differential tests
(issue #133): **Authorino** on a kind cluster (ground truth) and **PPE**
(`praxis-ai`) running the equivalent policy locally. The same request is fired at
both; status codes are compared.

- Case format, catalog, arms, legend: [`cases/README.md`](cases/README.md).
- What is being proven: `docs/proposals/00133_kuadrant-authpolicy-attribute-mapping.md`.

## Prerequisites

- `docker` (or podman), `kind`, `kubectl`, `curl`
- Rust stable 1.92+ (to build `praxis-ai`)
- Sibling checkouts: `kuadrant-operator`, `praxis-proxy/ai`, `praxis-proxy/policy`
  (this repo). Paths below write `<policy>` for this repo's root.

## Part A — Authorino cluster (ground truth)

```console
# 1. cluster + Kuadrant operator
git clone https://github.com/Kuadrant/kuadrant-operator && cd kuadrant-operator
make local-setup

# 2. control plane
kubectl apply -f <policy>/test-spike/testbed/10-kuadrant-cr.yaml
kubectl -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=300s

# 3. namespaces, gateway, route (upstream toystore.yaml ships neither)
kubectl apply -f <policy>/test-spike/testbed/00-namespaces.yaml
kubectl apply -f <policy>/test-spike/testbed/20-gateway.yaml
kubectl apply -f <policy>/test-spike/testbed/30-httproute.yaml

# 4. toystore app — must land in the `toystore` ns (the HTTPRoute backendRef)
kubectl apply -n toystore -f https://raw.githubusercontent.com/Kuadrant/kuadrant-operator/refs/heads/main/examples/toystore/toystore.yaml
kubectl -n toystore rollout status deploy/toystore --timeout=120s
```

Identity cases (`cel-id-*`, `opa-id-*`) also need the mock JWT issuer (RS256,
JWKS at `/jwks`, mints tokens on `POST /generate`, no OIDC discovery, per-boot
keypair so one instance serves both sides):

```console
kubectl apply -f <policy>/test-spike/testbed/40-mock-jwt.yaml
kubectl -n toystore rollout status deploy/mock-jwt --timeout=120s
```

Authorino reaches it in-cluster at `mock-jwt.toystore.svc.cluster.local:8088`;
`suite.sh` port-forwards it to `127.0.0.1:8088` for PPE on demand.

Smoke-test the ground truth by hand:

```console
GW=$(kubectl get gateway external -n api-gateway -o jsonpath='{.status.addresses[0].value}')
kubectl apply -f <policy>/test-spike/cases/cel-req-method.authpolicy.yaml
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.toystore.com' -X POST http://$GW/toys  # 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: api.toystore.com' -X GET  http://$GW/toys  # 403
```

## Part B — PPE side

```console
# build the proxy (package praxis-ai-proxy, bin praxis-ai)
cd ai && make release          # -> target/release/praxis-ai

# backend
docker run -d --name httpbin -p 9200:80 kennethreitz/httpbin
```

`run.sh`/`suite.sh` expect the binary at
`$PRAXIS_AI_DIR/target/release/praxis-ai` (`PRAXIS_AI_DIR` defaults to
`~/projects/src/github.com/praxis-proxy/ai`).

### Build against a local praxis-policy checkout

`praxis-ai` pulls the **published** `praxis-policy` crate. The Kuadrant compat
mode (issue #130, `kuadrant_compat` flag) is unmerged, so the `PPE-COMPAT` arm
needs the proxy built against *this* checkout. Add to the **praxis-ai** workspace
`Cargo.toml`:

```toml
# ai/Cargo.toml — LOCAL DEVELOPMENT ONLY, do not commit.
[patch.crates-io]
praxis-policy = { path = "../policy/crates/ppe" }
```

Only the facade needs patching; its sibling crates are workspace path deps and
come in transitively. `praxis-proxy-filter` requests `praxis-policy = "0.3.1"`
with `features = ["builtins"]`, both satisfied by the local facade. Verify and
rebuild:

```console
cd ai && cargo metadata --format-version 1 | grep -o '/[^"]*policy/crates/ppe'  # local path
make release
```

Remove the block and `cargo update -p praxis-policy` to return to the published crate.

## Run

```console
cd <policy>/test-spike
./suite.sh                 # full differential matrix (cluster + testbed required)
./suite.sh 'cel-req-*'     # subset by stem glob
```

Arms, results legend, and the case catalog: [`cases/README.md`](cases/README.md).

## Notes

- PPE uses its own `policy` filter, not the gRPC `kuadrant` filter — this spike
  compares attribute *semantics*, not the Envoy/Authorino wire integration.
- Identity cases fetch the mock JWKS over loopback; `praxis.yaml` sets
  `allow_private_idp: true` on the policy filter for that. Its JWKS transport is
  gated separately from `insecure_options.allow_private_endpoints` (which covers
  the httpbin upstream only).
- httpbin has no `/toys`; PPE curls hit `/anything`. Authorino uses `/toys`
  because its HTTPRoute matches that prefix.
