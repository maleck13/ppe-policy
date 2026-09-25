# Differential test cases

Each case is one authorization predicate expressed for both gateways, so the
same logical request can be fired at Authorino (ground truth) and at PPE and the
decisions compared. This is the evidence base for the Kuadrant AuthPolicy → PPE
attribute-mapping work (issue #133) and the attribute-dictionary compatibility
epic (issue #130).

For cluster/proxy setup see [`../SETUP.md`](../SETUP.md).

## File convention

A case is a **stem** plus up to four files sharing that stem:

| File | Side | Required | Purpose |
|------|------|----------|---------|
| `<stem>.authpolicy.yaml` | Authorino | yes | Kuadrant `AuthPolicy` — the ground truth. Applied to the live gateway. |
| `<stem>.expected` | — | yes | Expected decision per method: `<METHOD> <allow\|deny>` lines (`allow`→200, `deny`→403). `#` comments allowed. |
| `<stem>.ppe.yaml` | PPE | no | Correctly **mapped** PPE policy (Kuadrant attrs translated to the PPE dictionary). |
| `<stem>.naive.yaml` | PPE | no | **Naive** straight-translate: Kuadrant attributes copied verbatim. Expected to diverge — documents issue #130. |

A missing `.ppe.yaml` or `.naive.yaml` shows as `-` in the results table (that
arm is not run). A case with only `.authpolicy.yaml` + `.expected` is
ground-truth-only.

## Stem naming: `<evaluator>-<group>-<attr>`

- **evaluator**: `cel` | `opa`
- **group**: `req` | `hdr` | `id` | `mix` | `gap` | `dep` | `meta` | `alias` | `cross`
- **attr**: the attribute under test, e.g. `method`, `path`, `host`, `roles`

`metadata.name` in the AuthPolicy equals the stem, so a single 200/403 isolates
exactly one evaluator + attribute.

## Current cases

| Stem | What it proves |
|------|----------------|
| `cel-req-method` | CEL `request.method` → `http.method`. Mapped matches Authorino; naive denies POST (#130, CEL fails loud/error). |
| `opa-dep-method` | Authorino OPA deprecated `input.context.request.http.method` path. Ground-truth-only, no PPE arms yet. |
| `opa-alias-method` | The #130 sed-defeater: Rego indirects through a binding (`req := input.context.request.http`). Mapped keeps the binding but relocates the root to `input.http`; naive copies verbatim → `input.context` undefined → silent deny-all. |

## Attribute dictionaries (the crux of #130)

Kuadrant Well-Known Attributes vs PPE Attribute Bags:

| Kuadrant (WKA) | PPE bag | Note |
|----------------|---------|------|
| `request.method`, `request.path`, `request.host` | `http.method`, `http.path`, `http.host` | name mismatch |
| `request.headers.*` | `http.request_headers.*` | rename **and** reshape |
| `input.context.request.http.*` (OPA) | `input.http.*` | PPE OPA `input` = bag nested |
| `auth.identity.*` | `subject.*` / `client.*` / `claim.*` | non-mechanical (UDT) |
| `auth.metadata.*` | `metadata.*` | |
| — | `request.*` | **collision**: PPE `request.*` is trace/env metadata, NOT the HTTP request |

Indirection (`req := input.request`) is OPA/Rego-only — CEL has no let-binding —
so naive substitution is provably wrong for OPA. `opa-alias-method` is that case.

## Running

From the `test-spike/` directory (not here):

```console
# whole suite (dual-gateway differential, all cases)
./suite.sh

# a subset by glob on the stem
./suite.sh 'cel-req-*'
./suite.sh 'opa-*'

# single case, interactive: start PPE with one policy and curl it yourself
./run.sh cel-req-method            # mapped policy
./run.sh cel-req-method naive      # naive policy (#130)
./run.sh cel-req-method -t         # validate config only
```

`suite.sh` per case: applies the AuthPolicy → waits until enforcement is
actually live (probes the gateway, not just the CR status) → fires at the
gateway → deletes → runs PPE mapped → runs PPE naive → prints a matrix.
Progress is on stderr; the table is on stdout (`2>/dev/null` for table only).

Results table legend: `AUTHORINO`/`PPE-MAP` are checked against `.expected`
(`ok`/`DIFF`); `PPE-NAIVE` is checked against Authorino (`match`, or `#130` =
the expected divergence). `-` = arm not present.

Env knobs: `PRAXIS_AI_DIR` (praxis-ai checkout), `SETTLE` (fallback wait for
cases with no deny method to probe).

## Adding a case

1. Write `<stem>.authpolicy.yaml` (the Kuadrant predicate) and `<stem>.expected`.
2. Add `<stem>.ppe.yaml` with the attributes mapped to the PPE dictionary.
3. Optionally add `<stem>.naive.yaml` (verbatim copy) to document a #130 failure.
4. `./suite.sh '<stem>'` — no runner change needed; cases are auto-discovered.

Note on the naive arm: a method predicate that fails to resolve denies
*everything*, so naive "matches" ground truth on deny rows and only exposes the
bug on allow rows. A predicate whose naive form over-*allows* would expose #130
more sharply.
