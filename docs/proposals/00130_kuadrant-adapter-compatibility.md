---
issue: https://github.com/praxis-proxy/policy/issues/130
discussion: >-
  Output of a code spike (2026-09-25) that mapped the PPE evaluation
  seams where a Kuadrant compatibility adapter could plug in. Approach A
  was implemented and tested against the differential test spike
  (test-spike/); Approach B is assessed analytically against the same
  criteria, not yet built. Companion to proposal 00133, which fixes the
  attribute mapping this adapter must realise.
status: proposed (Approach A implemented as a spike on branch
  analysis-attributes-authpolicy, default-off, for maintainer review)
authors:
  - maleck13
graduation_criteria:
  - Both candidate approaches (cmf compat bridge vs sibling adapter
    PDPs) are described with their concrete PPE seams, cited to source.
  - Approach A is tested against the run-verbatim requirement and the
    current differential suite (method + identity cases); Approach B is
    assessed against the same criteria analytically (not yet built).
  - A recommended starting approach is stated with rationale, scoped so
    maintainers can confirm or redirect before implementation.
stakeholders:
  - araujof
  - terylt
---

# Kuadrant compatibility adapter — approach spike

## What?

Issue #130 asks: can an **unmodified** Kuadrant/Authorino AuthPolicy —
its CEL and Rego written against the Kuadrant Well-Known Attributes
(`request.method`, `auth.identity.*`, `input.context.request.http.*`) —
evaluate correctly on PPE **without rewriting the policy text**?

Proposal [00133](./00133_kuadrant-authpolicy-attribute-mapping.md)
fixed the field-by-field attribute mapping. This document is the output
of a code spike that answers the next question: **where does the
translation live, and how much does it cost.** It records two viable
approaches and recommends a starting point. It does not commit to a
final architecture — that is for maintainer discussion.

### Goals

- Capture both candidate approaches with their exact PPE seams.
- Test Approach A against the run-verbatim requirement and the
  current differential suite; assess Approach B against the same
  criteria analytically.
- Recommend a pragmatic starting approach, leaving the ultimate design
  open for maintainers.

### Non-goals

- Implementing either approach. This is a spike write-up.
- The `auth.metadata.*` phase. No PPE source exists for it today
  (00133's largest gap); no adapter reaches it. Those differential
  cases stay red by design.
- AST rewriting / transpilation (Option 2 in the #130 framing). The
  external `authpolicy-transpiler` demo already covers the
  ahead-of-time path; this document is about the run-unmodified path.

## Background: how PPE evaluation is wired

Three facts about the evaluation path decide whether verbatim Kuadrant
policy can run: how the bag is shaped, how each PDP reads it, and when
the bag is built. All verified against the workspace during the spike;
exact locations are in the [Code anchors](#code-anchors) appendix.

**The AttributeBag is a flat map of dotted keys.** Keys carry fixed
prefixes set by the `cmf` bridges: `http.*` for the HTTP request,
`subject.*` for identity, `request.*` for trace/env metadata. There is
no native `auth.*` or `metadata.*` namespace; the only namespace a
plugin can write today is `custom.*`. The bag is rebuilt from
`Extensions` *after* the Pre-phase hooks run, so a pre-authorization
plugin can shape it before any PDP sees it.

**Both built-in PDPs read the bag mechanically, with no injection
hook.** OPA flattens the bag's dotted keys into nested JSON input
(`subject.roles` → `input.subject.roles`). CEL builds its roots from
whatever top-level namespaces the bag happens to contain — add
`auth.identity.*` keys and an `auth` root appears on its own; the bag
also wins over per-step arguments on any name collision.

The consequence is the load-bearing one: **new keys in the bag become
new evaluation context for free.** Neither evaluator needs a code change
to see a namespace it has never seen before. That is exactly what lets
Approach A synthesise Kuadrant-shaped keys into the bag without touching
the PDPs.

Adding a whole new PDP is cheap too: a PDP is two traits — a resolver
(`evaluate(call, bag) -> decision`) and a factory (`kind()` + `build`).
Engines register by `kind` and reach the router via `PdpDialect::Custom`,
so adding one needs no core, evaluator, or router change. That is the
seam Approach B uses.

### The `request.*` namespace: collision or hygiene?

Kuadrant CEL writes `request.method` / `request.path`, but PPE's native
`request.*` is trace/env metadata (`request_id`, `timestamp`,
`trace_id`, …) with the HTTP request under `http.*`. They look like they
collide.

They do not. The bag is a flat map, and the trace leaf names are
disjoint from the WKA leaves (`method`, `path`, `host`, `scheme`), so
`request.method` can sit beside `request.timestamp` and resolve
correctly. The objection is hygiene — HTTP and trace data muddled under
one root — not correctness. That is why bag injection (Approach A) is
viable where a real collision would rule it out.

## Approach A — cmf compatibility bridge (recommended start)

A bag→bag re-key pass in the `cmf` layer (not a typed bridge — see the
implemented shape below), gated behind a compatibility-mode flag,
synthesises the Kuadrant-shaped keys from the existing bag sources:

- `http.method|path|host|scheme` → `request.<leaf>` and the OPA-deprecated
  `context.request.http.<leaf>`
- `http.request_headers.<name>` → `request.headers.<name>` and
  `context.request.http.headers.<name>`
- `subject.id` → `auth.identity.sub`; `subject.roles` →
  `auth.identity.roles`; `claim.<name>` → `auth.identity.<name>`

(`subject.roles` is a StringSet, so `auth.identity.roles` inherits the
same `"x" in …` membership idiom Kuadrant uses — see 00133's roles row.)

With those keys present in the bag, the **existing** `cel` and `opa`
PDPs evaluate verbatim Kuadrant policy unchanged: CEL gains a
`request` root carrying the HTTP fields and an `auth` root; OPA's
`bag_to_input` flatten produces `input.auth.identity.*` and
`input.context.request.http.*` for free.

- **Pros:** one evaluator each, least duplication; closest to 00133's
  "shim injects aliases into the eval context"; the run-verbatim
  property and Rego-binding survival (`req := input.context.request.http`)
  come for free because a real document is present at eval time.
- **Cons:** a code change in `ppe-apl-cmf` (the fixed-prefix layer);
  must be flag-gated so it never pollutes the bag for non-Kuadrant
  users; the `request.*` root mixes HTTP and trace data (hygiene).
- **Footprint:** one bridge module + a compat flag + mapping logic.
  No new crate, no PDP duplication.

### Implemented shape (spike, default-off)

Approach A is implemented on `analysis-attributes-authpolicy` so
maintainers can read the concrete seams rather than a sketch. All
additive; the flag defaults off, so existing behaviour is unchanged.

- `ppe-apl-cmf/src/kuadrant.rs`: `apply_kuadrant_compat(&mut AttributeBag)`
  — a bag→bag re-key pass run **after** the typed bridges. It only reads
  keys already present and writes WKA aliases, so capability filtering is
  inherited for free (a stripped value has no source, so no alias) and
  the pass is idempotent. 5 unit tests.
- `ppe-apl-cmf` exposes it via `BagBuilder::with_kuadrant_compat()`.
- `ppe-core`: `engine_settings.kuadrant_compat: bool` (serde default
  false) + `PolicyConfig::kuadrant_compat()` + `PolicyEngine::kuadrant_compat()`,
  which mirrors `dispatch_mode()` (reads `load_runtime().policy_config`).
  The engine is the config carrier, so the flag is not threaded through
  `install_handler`'s parameters.
- `ppe-apl-runtime`: `AplRouteHandler` gains `with_kuadrant_compat(bool)`;
  the visitor sets it from `mgr.kuadrant_compat()`; the single bag-build
  call site applies the pass when the flag is on.
- e2e proof in `http_route_e2e.rs`: a PDP that allows iff the bag carries
  the WKA `request.method`. Compat OFF → deny (only `http.method` present);
  compat ON → allow (aliased). Exercises config → engine → visitor →
  handler → bag → PDP, not a unit call.

This is a spike for review, not a merge proposal — the architectural
question below (A vs B) is still open.

## Approach B — sibling adapter PDPs

New PDP crates `kuadrant-opa` / `kuadrant-cel` implementing
`PdpFactory` + `PdpResolver` with `PdpDialect::Custom`. They reuse
regorus / cel-interpreter exactly as the built-ins do, but swap the
input/activation builder for a Kuadrant-shaped one internally (the
`request` remap and `auth.*` synthesis live inside the resolver, never
touching the shared bag).

- **Pros:** fully isolated; zero bag pollution; no compat flag on the
  shared path; the built-in PDPs are untouched.
- **Cons:** two new crates duplicating resolver plumbing (see the
  [Code anchors](#code-anchors) appendix) and two PDPs to maintain;
  operators must select the `kuadrant-*` kind explicitly.
- **Footprint:** larger — two crates, sustained maintenance of a
  parallel resolver pair.

## Why both survive the sed-defeater

`opa-alias-method` (Rego `req := input.context.request.http; allow {
req.method == "POST" }`) defeats string substitution. Both A and B
defeat it too, and for the same reason: each presents a real
`input.context.request.http` document to the evaluator, so the
let-binding resolves at eval time. Only AST/text rewriting (the
non-goal Option 2) has to chase the binding. Neither A nor B rewrites
policy text.

## Complexity against the differential suite

`test-spike/` current cases and their fate under an adapter. The **A
(tested)** column is the observed result of the spike's `PPE-COMPAT`
arm; the **B (predicted)** column is the analytical expectation for the
unbuilt sibling PDPs.

| Case | Needs | A (tested) | B (predicted) |
|------|-------|--------------|---------------|
| `cel-req-method` | `request.method` = HTTP in CEL | naive arm passes | naive arm passes |
| `opa-dep-method` | `input.context.request.http.method` | reachable | reachable |
| `opa-alias-method` | binding over `input.context.request.http` | naive arm passes | naive arm passes |
| `cel-id-roles` | `auth.identity.roles` in CEL | naive arm passes | naive arm passes |
| `opa-id-roles` | `input.auth.identity.roles` in OPA | naive arm passes | naive arm passes |
| (`*-meta-*`, future) | `auth.metadata.*` | **stays red** | **stays red** |

- **Architectural risk: low.** Seams are clean; no core changes for
  either approach.
- The current suite (method + identity) is a **small, mechanical
  subset** of 00133's mapping — HTTP fields and identity claims only.
  An adapter flips the **naive** arms from failing to passing.
- **`auth.metadata.*` is out of reach for any adapter** — no PPE
  source. Those cases document the gap, not an adapter defect.
- **Security-critical:** default `on_error: deny` means any *unmapped*
  WKA reference fails closed silently. Mapping completeness is a
  correctness/security property. Fail-closed is the safe direction, but
  a silent deny on a supposedly-supported attribute is a compatibility
  bug that `praxis -t` validation cannot catch (see 00133's evidence).

## Recommendation

Start with **Approach A** for its smaller footprint: a single
flag-gated bridge, no crate duplication, and it exercises the existing,
already-tested PDPs. It is the fastest route to turning the differential
suite's naive arms green and producing concrete run-verbatim evidence
for maintainer discussion.

Approach B remains on the table as the isolation-first alternative. The
choice between "translate once in the bag" (A) and "translate inside a
dedicated resolver" (B) is the substantive architectural question for
maintainers; this spike does not foreclose it. A can also be a stepping
stone: if hygiene or isolation concerns win, the mapping logic proven
under A transfers into B's resolver with little waste.

## Open questions for maintainers

1. Bag hygiene: is a flag-gated `request.*` root that mixes HTTP and
   trace data acceptable, or is the isolation of B required?
2. Flag surface: where does compatibility mode live — `engine_settings`,
   a `global` key, or per-PDP config?
3. Scope of the first cut: method + identity only (current suite), or
   the full 00133 runtime-observable subset (headers, source, etc.)?
4. Does `auth.metadata.*` justify its own work item now, or stay
   deferred as a known gap?

## Code anchors

Exact locations for the wiring described above, verified on
`analysis-attributes-authpolicy` during the spike. Line ranges drift;
treat them as starting points.

| What | Location |
|------|----------|
| `PdpResolver` trait (`evaluate(&PdpCall, &AttributeBag) -> PdpDecision`) | `crates/ppe-apl-core/src/step.rs:352-369` |
| `PdpFactory` trait (`kind()` + `build(config)`) | `crates/ppe-apl-core/src/step.rs:385-402` |
| `PdpDialect::Custom(String)` + `pdp(name)` step form | `crates/ppe-apl-core/src/step.rs:301-343` |
| Config dispatch, factory-by-`kind` | `crates/ppe-apl-runtime/src/visitor.rs:375-402` |
| OPA `bag_to_input` flatten (dotted keys → nested JSON) | `builtins/pdps/opa/src/input.rs:37-92` |
| `OpaResolver::evaluate` (sole caller of `bag_to_input`) | `builtins/pdps/opa/src/resolver.rs:467` |
| CEL `bag_to_context` (dynamic roots) | `builtins/pdps/cel/src/activation.rs:43-79` |
| CEL bag-wins-over-`extra_args` on collision | `builtins/pdps/cel/src/activation.rs:67-76` |
| `AttributeBag` flat dotted-key map | `crates/ppe-apl-core/src/attributes.rs:82-98` |
| `cmf` fixed prefixes | `crates/ppe-apl-cmf/src/lib.rs:19-41` |
| `request.*` trace/env leaves | `crates/ppe-apl-cmf/src/request.rs:20-32` |
| Bag rebuilt from `Extensions` after Pre-phase hooks | `crates/ppe-apl-runtime/src/route_handler.rs:381-403` |
| Approach B: OPA / CEL resolver plumbing to duplicate | `builtins/pdps/opa/src/resolver.rs:446-483`, `builtins/pdps/cel/src/resolver.rs:395-485` |
