# Live request.id comparison

This local test compares one Kuadrant AuthPolicy predicate, `request.id != ''`,
with the same CEL predicate in PPE. PPE runs twice from one policy
file: `kuadrant_compat: false` and `true`. The three case files are in
[`cases/`](cases/). The suite is not part of CI.

## Prerequisites

- `docker` (or podman), `kind`, `kubectl`, `curl`, and Rust stable 1.92+.
- Sibling checkouts of `kuadrant-operator`, `praxis-proxy/ai`, and this policy
  worktree.
- A `praxis-ai` proxy that passes the inbound `x-request-id` to the policy
  filter's HTTP request headers.

## Authorino gateway

From the Kuadrant operator checkout, start its local environment:

```console
make local-setup
```

Then apply this testbed from the policy worktree:

```console
kubectl apply -f kuadrant-compat/testbed/10-kuadrant-cr.yaml
kubectl -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=300s
kubectl apply -f kuadrant-compat/testbed/00-namespaces.yaml
kubectl apply -f kuadrant-compat/testbed/20-gateway.yaml
kubectl apply -f kuadrant-compat/testbed/30-httproute.yaml
kubectl apply -n toystore -f https://raw.githubusercontent.com/Kuadrant/kuadrant-operator/refs/heads/main/examples/toystore/toystore.yaml
kubectl -n toystore rollout status deploy/toystore --timeout=120s
```

The testbed uses an Istio gateway. Envoy generates `x-request-id` when it is
absent by default, and an edge gateway may replace a client-supplied value.
The suite sends two nonempty IDs and checks that Authorino resolves
`request.id` for both, regardless of which value reaches it. PPE prefers the
inbound header and uses its host request ID only when the header is absent.

## PPE proxy

The suite expects `praxis-ai` at
`$PRAXIS_AI_DIR/target/release/praxis-ai` (default: the sibling
`~/projects/src/github.com/praxis-proxy/ai` checkout) and httpbin on
`127.0.0.1:9200`:

```console
docker run -d --name httpbin -p 9200:80 kennethreitz/httpbin
```

Build `praxis-ai` against this policy worktree, since the published
`praxis-policy` crate does not contain this change. In the ai workspace
`Cargo.toml`, point the patch at the absolute path to this worktree's facade
crate:

```toml
[patch.crates-io]
praxis-policy = { path = "/absolute/path/to/policy-worktree/crates/ppe" }
```

Then run `make release` in the ai checkout. The patch is local development
configuration and should not be committed in the ai repository.

## Run

```console
cd kuadrant-compat
./suite.sh
```

The suite applies the AuthPolicy, checks Authorino, deletes it, then runs PPE
with the flag off and on. It prints all decisions and exits nonzero if
Authorino differs from `cases/cel-req-id.expected`, if the flag-off policy
does not deny both requests, or if the flag-on policy differs from the expected
decisions. It also removes the AuthPolicy on exit after an error.

PPE uses its local `policy` filter for this comparison; it does not use the
Envoy/Authorino wire integration. Authorino's route is `/toys`; PPE's
httpbin route is `/anything`.
