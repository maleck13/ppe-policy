# Embedded request rate limit PoC

`ratelimit/limitador` runs at `http.request` and keeps counters in the
process. It is available only with the `experimental-ratelimit` Cargo feature.
Each plugin instance owns one Limitador limiter, so counters reset on restart
and are not shared across replicas. The plugin serializes each in-memory
check/update across concurrent requests to that instance.

This first slice supplies two CEL variables to Limitador:

| Variable | PPE source | Required capability |
| --- | --- | --- |
| `subject_id` | Resolved `security.subject.id` | `read_subject` |
| `http_method` | `HttpExtension.method` | `read_headers` |

There is no `auth.identity.*` or `request.*` compatibility mapping yet.
Missing identity or HTTP method denies the request before updating a counter.
A Limitador evaluation error also denies. An exceeded limit sets
`proto_error_code: 429` for the host to render as HTTP 429.

```yaml
engine_settings:
  dispatch: policy

plugins:
  - name: app-ratelimit
    kind: ratelimit/limitador
    hooks: [http.request]
    mode: sequential
    capabilities: [read_subject, read_headers]
    config:
      namespace: toystore
      counter_capacity: 1000
      limits:
        - max: 5
          seconds: 60
          conditions: ["subject_id == 'alice'", "http_method == 'GET'"]
        - max: 2
          seconds: 60
          conditions: ["subject_id == 'bob'", "http_method == 'GET'"]

global:
  authorization:
    pre_invocation:
      - "run(app-ratelimit)"
```

The `run` step is required under policy dispatch. The `hooks` list declares
the hook for config validation; the factory registers the handler in code.
Authentication must resolve the subject before the `http.request` invocation.

Demo the in-process decision sequence from this worktree with:

```console
cargo test -p praxis-policy-builtins --features experimental-ratelimit --test ratelimit counts_alice_and_bob_independently_and_returns_429 -- --exact --nocapture
```

The output shows Alice's POST allowed without using a GET counter, five Alice
GETs and two Bob GETs allowed, then Alice's sixth and Bob's third GET denied
with `proto_error_code=429`. Each test starts a fresh engine, so rerunning the
command resets the counters. This exercises PPE's route and plugin in process;
it does not start an HTTP server or show an HTTP response on the wire.

Run the full in-process proof with:

```console
cargo test -p praxis-policy-builtins --features experimental-ratelimit --test ratelimit
```
