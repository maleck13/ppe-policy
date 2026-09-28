---
issue: https://github.com/praxis-proxy/policy/issues/133
discussion: >-
  Consolidated from the agent-authored brainstorm at
  docs/brainstorms/kuadrant-authpolicy/attribute-mapping.md and the
  companion mapping tables that lived in the authpolicy-transpiler
  demo repo (well-known-attributes-mapping.md,
  kuadrant-ppe-compatibility.md, request-attributes-mapping.md).
  This proposal is the canonical, policy-repo home for that material.
status: proposed
authors:
  - maleck13
graduation_criteria:
  - This document contains a field-by-field mapping of every Kuadrant
    RFC 0002 well-known attribute to its PPE equivalent, each with a
    status (Mapped / Mapped-path / Mapped-shape / Different-model /
    Gap / N/A).
  - A single consolidated table lists every unsupported (Gap) and
    lossy (Mapped-path / Mapped-shape / Different-model) mapping with
    the reason.
  - PPE-side citations are verified against this repo; cross-repo
    (praxis-proxy) citations are explicitly marked unverified.
  - The runtime-observable subset (request line, headers, identity
    claims) is backed by dual-gateway evidence (Authorino vs PPE
    status codes) from the test spike.
stakeholders:
  - araujof
  - terylt
---

# Kuadrant AuthPolicy → PPE attribute mapping

## What?

A field-by-field mapping of Kuadrant/Authorino
[RFC 0002 well-known attributes](https://docs.kuadrant.io/1.0.x/architecture/rfcs/0002-well-known-attributes/)
to their Praxis Policy Engine (PPE) equivalents, plus a clear list of
the mappings that are **unsupported** or **lossy**.

Authorino evaluates authorization against an attribute bag built from
Envoy's `CheckRequest` plus synthesized auth phases. PPE evaluates
against its own bag populated by the Praxis host. For an existing
Kuadrant CEL/OPA policy to behave identically on PPE, each attribute
path must resolve to the same value. This document records where that
holds, where it holds with a caveat (lossy), and where it cannot hold
today (gap).

### Overview

Of RFC 0002's ~58 attributes, **10 map cleanly** to PPE, **11 map but
lossily** (different path, shape, or model — the policy must be rewritten
or aliased), and **~35 have no PPE value today**; two are Envoy-specific
(N/A). Full counts: [Summary counts](#summary-counts).

The runtime-observable subset — request line, headers, identity claims —
maps well enough to run real policies, and is the part backed by
dual-gateway test evidence ([Test matrix and evidence](#test-matrix-and-evidence)).
The largest functional gap is `auth.metadata.*` (external metadata fetch):
no PPE pipeline phase reaches it.

The rest of this document is reference: the exhaustive
[mapping matrix](#field-by-field-mapping-matrix) row by row, then the
single actionable
[unsupported / lossy list](#consolidated-unsupported--lossy-list) the
graduation criteria require.

### Goals

- One checked-in spec that maps every RFC 0002 attribute to PPE.
- A single, unambiguous list of unsupported and lossy mappings.
- Citations verified against PPE source; external citations flagged.
- Ground the runtime-observable rows in dual-gateway test evidence.

### Non-goals

- Building the compatibility shim plugin or the metadata phase. Those
  are separate work items; this document scopes and justifies them.
- Praxis-proxy host changes. Those are noted as host-required but
  owned by the proxy repo.

## Status key

- **Mapped** — direct equivalent exists in PPE at an equivalent path.
- **Mapped (path)** — same data, different attribute path. *Lossy:*
  the policy must be rewritten or aliased.
- **Mapped (shape)** — same concept, different representation (e.g.
  array membership → per-name booleans). *Lossy:* predicate form
  differs.
- **Different model** — PPE handles the concept architecturally
  differently (e.g. SPIFFE identity vs raw certificate). *Lossy.*
- **Gap** — no PPE equivalent. `custom.*` / `data.*` can bridge only
  if the host populates them.
- **N/A** — Envoy/Kubernetes-specific, not applicable to Praxis.

## Attribute consumption in Authorino

All evaluators consume the same authorization JSON built by
`GetAuthorizationJSON()`. Only the access form differs:

| Evaluator | Input form | Attribute prefix |
|---|---|---|
| OPA (v0 + v1) | Full JSON as `rego.EvalInput` | `input.auth.identity.*`, `input.request.*`, `input.context.*` |
| CEL | 5 `protobuf.Struct` bindings via `AuthJsonToCel()` | `auth.identity.*`, `request.*`, `source.*`, `destination.*`, `metadata.*` |
| Pattern matching (GJSON) | Raw JSON string | `auth.identity.*`, `request.*`, `context.*` |
| Response / Conditions | Dispatches to GJSON or CEL | Same as whichever is configured |

CEL cannot access the deprecated `context.*` path; OPA and GJSON can
access both old and new paths. OPA v0 vs v1 is a Rego *syntax*
difference, not an input-shape difference — the input document is
identical.

## Field-by-field mapping matrix

### Request attributes

Origin: Envoy `CheckRequest` (`HttpRequest`).

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `request.id` | String | `request.request_id` | Mapped (path) | `x-request-id` header value |
| `request.time` | Timestamp | `request.timestamp` | Mapped (path) | Time of first byte; check type compat (string vs protobuf Timestamp) |
| `request.protocol` | String | — | Gap | HTTP version (1.0/1.1/2/3) |
| `request.scheme` | String | `http.scheme` | Mapped | |
| `request.host` | String | `http.host` | Mapped | |
| `request.method` | String | `http.method` | Mapped | |
| `request.path` | String | `http.path` | Mapped | Full path incl. query string |
| `request.url_path` | String | `http.path` | Mapped (path) | PPE does not separate path from url_path — both collapse to `http.path` |
| `request.query` | String | — | Gap | Query string; proxy has it (`req.uri.query()`) but doesn't pass it |
| `request.headers` | Map\<String,String\> | `http.request_headers.*` | Mapped (shape) | PPE has flat `http.request_headers.<name>`; Kuadrant uses map access `request.headers["name"]` |
| `request.referer` | String | `http.request_headers.referer` | Mapped (path) | Via headers |
| `request.useragent` | String | `http.request_headers.user-agent` | Mapped (path) | Via headers |
| `request.size` | Number | — | Gap | Request size in bytes |
| `request.body` | JSONString | — | Gap | Body; buffered by Praxis for entity routes (MCP/LLM) only, not pure L7 |
| `request.raw_body` | Bytes | — | Gap | Raw body bytes |
| `request.context_extensions` | Map\<String,String\> | — | N/A | Envoy-specific, not sent upstream |

### Source attributes (downstream client)

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `source.address` | String | — | Gap | Client IP; bridgeable via `custom.*` if host injects |
| `source.port` | Number | — | Gap | |
| `source.service` | String | — | Gap | Envoy service-mesh concept |
| `source.labels` | Map\<String,String\> | — | Gap | Pod/VM labels |
| `source.principal` | String | `caller_workload.spiffe_id` | Different model | PPE uses SPIFFE identity, not raw principal |
| `source.certificate` | String | — | Gap | Raw X.509 PEM |

### Destination attributes (upstream)

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `destination.address` | String | — | Gap | |
| `destination.port` | Number | — | Gap | |
| `destination.service` | String | — | Gap | |
| `destination.labels` | Map\<String,String\> | — | Gap | |
| `destination.principal` | String | `this_workload.spiffe_id` | Different model | |
| `destination.certificate` | String | — | Gap | |

### Connection attributes

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `connection.id` | Number | — | Gap | |
| `connection.mtls` | Boolean | `caller_workload.attestor` | Different model | PPE: check `attestor == "mtls"` |
| `connection.requested_server_name` | String | — | Gap | SNI |
| `connection.tls_session.sni` | String | — | Gap | |
| `connection.tls_version` | String | — | Gap | |
| `connection.subject_local_certificate` | String | — | Gap | |
| `connection.subject_peer_certificate` | String | — | Gap | |
| `connection.dns_san_local_certificate` | String | — | Gap | |
| `connection.dns_san_peer_certificate` | String | — | Gap | |
| `connection.uri_san_local_certificate` | String | — | Gap | |
| `connection.uri_san_peer_certificate` | String | — | Gap | |
| `connection.sha256_peer_certificate_digest` | String | — | Gap | |

### Auth — identity (`auth.identity`)

For **JWT** auth, `auth.identity` is the full decoded JWT payload. For
**API key** auth, it is the entire `k8s.Secret` object.

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `auth.identity` (JWT) | Object | `claim.*` (recursive walk) | Mapped | All JWT claims via recursive walk |
| `auth.identity.sub` | String | `subject.id` + `claim.sub` | Mapped | |
| `auth.identity.iss` | String | `claim.iss` | Mapped | |
| `auth.identity.aud` | String/Array | `claim.aud` + `client.authorized_audiences` | Mapped | |
| `auth.identity.exp` | Number | `claim.exp` | Mapped | |
| `auth.identity.roles` | Array | `role.*` (booleans) + `claim.roles` | Mapped (shape) | Authorino: `'x' in roles`. PPE: `has(role.x) && role.x` |
| `auth.identity.permissions` | Array | `perm.*` (booleans) + `claim.permissions` | Mapped (shape) | Same shape difference as roles |
| `auth.identity.groups` | Array | `team.*` (booleans) + `claim.groups` | Mapped (shape) | PPE maps groups + teams → `team.*` |
| `auth.identity.teams` | Array | `team.*` (booleans) + `claim.teams` | Mapped (shape) | |
| `auth.identity.email` | String | `claim.email` | Mapped | |
| `auth.identity.email_verified` | Boolean | `claim.email_verified` | Mapped | |
| `auth.identity.realm_access.roles` | Array | `claim.realm_access.roles` | Mapped | Recursive walk handles nested |
| `auth.identity.<any_claim>` | Any | `claim.<any_claim>` | Mapped | Full recursive walk |
| `auth.identity` (API Key) | k8s.Secret | — | Gap | `IdentityScheme::ApiKey` variant exists, no plugin implements it |
| `auth.identity.metadata.annotations.*` | String | — | Gap | API-key user metadata convention |
| `auth.identity.data.*` | String | — | Gap | API-key secret data |

### Auth — other phases

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `auth.metadata` | Map\<String,Any\> | — | Gap | External metadata (HTTP fetch, OIDC userinfo). No PPE pipeline phase. |
| `auth.authorization` | Map\<String,Any\> | — | Gap | Results from earlier authz evaluators |
| `auth.response` | Map\<String,Any\> | — | Gap | Exported response objects |
| `auth.callbacks` | Map\<String,Any\> | — | Gap | Post-auth callback results |

### Metadata and filter state

| Kuadrant Attribute | Type | PPE Equivalent | Status | Notes |
|---|---|---|---|---|
| `metadata` | Metadata | `meta.*` | Different model | PPE: entity metadata (type/name/tags). Authorino: Envoy dynamic metadata |
| `filter_state` | Map\<String,String\> | — | N/A | Envoy-specific |

### PPE claim-mapper presets

`identity/jwt` supports four presets determining how claims map to
`role.*` / `perm.*` / `team.*`:

| Field | standard | keycloak | auth0 | cognito |
|---|---|---|---|---|
| `subject.id` | `sub` | `sub` | `sub` | `sub` |
| `role.*` | `roles[]` | `realm_access.roles[]` | — | — |
| `perm.*` | `permissions[]` → `scope` | `scope` | `permissions[]` → `scope` | `scope` |
| `team.*` | `teams[]` → `groups[]` | — | — | `cognito:groups[]` |
| `client.client_id` | `client_id` → `azp` | `client_id` → `azp` → `clientId` | `client_id` → `azp` | `client_id` |

`→` = fallback chain.

### PPE-only attributes (no Kuadrant equivalent)

`delegation.*`, `agent.*`, `llm.*`, `mcp.*`, `completion.*`,
`provenance.*`, `framework.*`, `data.*`, `args.*`, `result.*`,
`custom.*`, `session.*`.

### Summary counts

| Status | Count | Meaning |
|---|---|---|
| Mapped | 10 | Direct path match |
| Mapped (path) | 4 | Same data, different path — **lossy** |
| Mapped (shape) | 4 | Same concept, different representation — **lossy** |
| Different model | 3 | Architecturally different (SPIFFE, mtls, metadata) — **lossy** |
| Gap | ~35 | No PPE equivalent |
| N/A | 2 | Envoy-specific |

## Consolidated unsupported / lossy list

The single list the graduation criteria require. "Lossy" = works but
the policy must change form or loses fidelity; "Unsupported" = the
value does not exist in PPE today.

The **Solution** column says where each value should come from. Its
vocabulary: `Praxis → PPE` (proxy has it, host injects, no PPE change);
`Praxis + PPE` (proxy surfaces it *and* PPE models a new field);
`PPE: plugin` (new plugin); `PPE: hook` (new enrichment capability);
`Shim/rewrite` (compatibility-plugin alias or transpiler); `N/A`.

### Lossy (works with rewrite / aliasing)

| Attribute | Kind | Why lossy | Solution |
|---|---|---|---|
| `request.id` | path | → `request.request_id` | Shim/rewrite |
| `request.time` | path | → `request.timestamp`; string vs protobuf Timestamp type | Shim/rewrite |
| `request.url_path` | path | collapses into `http.path` (no separate url_path) | Shim/rewrite |
| `request.referer` / `request.useragent` | path | only via `http.request_headers.*` | Shim/rewrite |
| `request.headers` | shape | flat `http.request_headers.<name>` vs map access `["name"]` | Shim/rewrite (present map) |
| `auth.identity.roles` / `permissions` / `groups` / `teams` | shape | array membership → per-name booleans (`has(role.x) && role.x`) | Shim/rewrite (transpiler already handles) |
| `source.principal` / `destination.principal` | model | SPIFFE identity, not raw principal | Shim/rewrite (map `caller_workload.spiffe_id`) |
| `connection.mtls` | model | `caller_workload.attestor == "mtls"`, not a boolean | Shim/rewrite (map `attestor`) |
| `metadata` | model | entity metadata, not Envoy dynamic metadata | Shim/rewrite (map `meta.*`) |

### Unsupported (no PPE value today)

| Attribute | Why unsupported | Solution |
|---|---|---|
| `request.query` | Proxy has it (`req.uri.query()`) but doesn't pass it | Praxis → PPE |
| `source.address` | Client IP known only to proxy | Praxis → PPE |
| `connection.mtls` state (raw) | TLS state at listener (`downstream_tls`) not passed | Praxis → PPE |
| `source.principal` (mTLS) | `peer_identity` available but `WorkloadIdentity` not populated | Praxis → PPE |
| `request.protocol` | HTTP version not surfaced to filter context | Praxis + PPE |
| `request.size` | Not surfaced | Praxis + PPE |
| `source.port` / `destination.*` | Not surfaced to filter context | Praxis + PPE |
| `source.service` / `source.labels` | Mesh data; may not exist off-Envoy | Praxis + PPE |
| `source.certificate` / `connection.*` certs, SNI, tls_version, id | Not surfaced | Praxis + PPE |
| `request.body` / `request.raw_body` | Buffered for entity routes (MCP/LLM) only, not pure L7 | Praxis (enable buffering) + PPE (surface for L7) |
| `auth.metadata` | No metadata pipeline phase — biggest functional gap | PPE: plugin (callout) *or* Praxis fetch+inject |
| `auth.authorization` / `auth.response` / `auth.callbacks` | No incremental auth-JSON model | PPE: plugin (pipeline phases) |
| `auth.identity` (API key), `.metadata.annotations.*`, `.data.*` | `IdentityScheme::ApiKey` exists, no plugin | PPE: plugin (`identity/apikey`) |
| Identity extended properties (`defaults`/`overrides`) | PPE presets are static | PPE: hook (post-auth enrichment) |
| Multi-auth priority (JWT → API-key fallback) | Multiple JWT issuers only, no cross-method priority | PPE: plugin (multi-method resolver) |

### Host-required detail (`Praxis → PPE` rows)

The `Praxis → PPE` rows above are data Praxis *has* but does not pass.
A `custom.*` injection in the proxy's `attach_http_attributes` closes
them without PPE changes:

| Data | Praxis source (external repo, unverified) | Bridge as |
|---|---|---|
| Client IP | `ctx.client_addr` | `custom.source.address` |
| TLS state | `ctx.downstream_tls` | `custom.connection.tls` |
| mTLS peer identity | `ctx.peer_identity.spiffe_id` | populate `WorkloadIdentity` |
| Query string | `req.uri.query()` | `custom.request.query` |

## Compatibility approach

The implementation of this compatibility layer is tracked by
[issue #130](https://github.com/praxis-proxy/policy/issues/130) (Epic:
AuthPolicy/PPE attribute dictionary compatibility). This document is the
analysis that feeds it. The two strategies below map directly onto #130's
Option 1 and Option 2.

Two strategies for running unmodified Kuadrant policies on PPE:

1. **Compatibility shim** (#130 Option 1, adapter input) — a PPE plugin,
   gated behind a "compatibility mode" flag, injects Kuadrant-vocabulary
   aliases (`request.method`, `auth.identity.*`) into the evaluation
   context alongside PPE-native attributes. Both resolve to the same
   value.
2. **AST rewriting** (#130 Option 2, semantic compiler) — parse each
   rule into an AST and rewrite whole subtrees to PPE paths.

The shim is preferred: it survives variable binding / aliasing in both
CEL (`let req = request`) and Rego (`req := input.request`), which
lexical rewriting cannot handle without a full parser. The transpiler
covers the ahead-of-time case; the shim covers the run-unmodified
case.

### Namespace collision (the sharpest trap)

Per #130: PPE's *own* `request.*` bag is environment/trace metadata
(`request.request_id`, `request.timestamp`, `request.trace_id`), **not**
the HTTP request. So the Kuadrant `request.*` namespace splits across two
PPE bags — `request.method` → `http.method`, but `request.id` →
`request.request_id` — and one of them (`request.*`) is a false friend
that resolves to the wrong thing rather than failing loudly.

## Test matrix and evidence

The runtime-observable rows are proven with a dual-gateway spike: the
same predicate is expressed as an Authorino AuthPolicy and an
equivalent PPE policy, the same requests are fired at both, and the
status codes are compared. See `test-spike/` in this repo. Test IDs
follow `<evaluator>-<group>-<attr>` (e.g. `cel-req-method`,
`opa-dep-method`), aligned with the CEL/OPA matrix below.

Coverage families: request line (`req`), headers (`hdr`), identity
claims (`id`), mixed namespaces (`mix`), source/connection gaps
(`gap`), deprecated `context.*` (`dep`), metadata gap (`meta`),
variable aliasing (`alias`), cross-evaluator consistency (`cross`).

Gap and metadata rows are expected to **fail** on PPE today — those
tests document the gap rather than assert compatibility.

### Naive straight-translate arm (evidence for #130)

Each attribute has two PPE-side policies, not one:

- **mapped** (`policy-test.yaml`) — the correct PPE path (`http.method`).
- **naive** (`policy-naive.yaml`) — the Kuadrant predicate copied
  *verbatim* (`request.method`), the lift-and-shift #130 warns against.

The naive arm is the evidence the epic actually needs: it proves the
mistranslation is a *runtime* failure, invisible to compile/validation.

Observed for `cel-req-method` (POST expected allow, GET expected deny):

| Gateway / policy | POST | GET |
|---|---|---|
| Authorino (ground truth) | 200 | 403 |
| PPE mapped (`http.method`) | 200 | 403 |
| PPE naive (`request.method` verbatim) | **403** | 403 |

Both PPE configs pass `praxis -t` validation (exit 0); the divergence
only appears at request time. Notably the naive CEL case failed
**silently** — a plain 403 deny with no evaluation error or panic in the
proxy log. This *corrects* #130's expectation that CEL mistranslation
"tends to panic": here it failed closed. Fail-closed is safer than
fail-open, but it is still wrong behaviour and would silently break a
migrated allow rule.

## Open questions

1. **Deprecated `context.*` in OPA** — Authorino OPA supports it, CEL
   does not. Should the shim support it (broader compat, perpetuates a
   deprecated path)?
2. **`request.headers` shape** — presenting a map object for CEL/OPA
   given PPE's flat bag and its nested-tree activation.
3. **Identity extended properties** — how common in real AuthConfigs?
   If common, PPE needs a post-auth enrichment hook.
4. **Metadata phase** — in scope for the compatibility layer or
   explicitly out?
5. **`request.body` for pure L7** — enable body buffering for
   body-inspecting policies, or out of scope?
6. **Ownership** — the quick-win `custom.*` injections are Praxis-side
   (proxy repo). Who owns them?

## References

PPE-side citations verified against this repo at the time of writing.
Cross-repo (praxis-proxy) and Authorino citations are **unverified
here** — they point at external repositories.

### PPE (verified — this repo)

| Reference | Location |
|---|---|
| HTTP attributes (`http.method/path/host/scheme`, `request_headers.*`) | `crates/ppe-apl-cmf/src/http.rs` |
| Claim recursive walk | `crates/ppe-apl-cmf/src/security.rs:136-140` |
| Client claim walk | `crates/ppe-apl-cmf/src/security.rs:209` |
| Custom namespace walk | `crates/ppe-apl-cmf/src/custom.rs:19-21` |
| Claim-mapper presets | `builtins/plugins/identity-jwt/src/presets.rs:24-26` + `presets/{standard,keycloak,auth0,cognito}.json` |
| CEL activation (flat bag → nested tree) | `builtins/pdps/cel/src/activation.rs` |
| `IdentityScheme::ApiKey` (variant, no plugin) | `crates/ppe-core/src/identity/payload.rs:91` |
| Global authz without authentication (`authentication: Option`) | `crates/ppe-core/src/config.rs:237` |

### Authorino / Kuadrant (unverified — external)

- RFC 0002 well-known attributes: https://docs.kuadrant.io/1.0.x/architecture/rfcs/0002-well-known-attributes/
- `GetAuthorizationJSON()` — `pkg/service/auth_pipeline.go`
- `AuthJsonToCel()` — `pkg/expressions/cel/expressions.go`
- OPA input passing — `pkg/evaluators/authorization/opa.go`
- Identity extended properties — `pkg/evaluators/identity.go` (`ResolveExtendedProperties`)
- Metadata evaluators — `pkg/evaluators/metadata/{generic_http,user_info,uma}.go`

### Praxis proxy (unverified — external repo)

- HTTP attribute population — `filter.rs` (`attach_http_attributes`)
- Filter context (`client_addr`, `downstream_tls`, `peer_identity`) — `context.rs` (`HttpFilterContext`)
- `custom.*` injection example — `filter.rs` (`attach_llm_attributes`)
