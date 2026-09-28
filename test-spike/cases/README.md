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
| `<stem>.tokens` | — | no | Presence marks an **identity case**. Lines `<token-key> <claims-json>`; each key mints a JWT with those extra claims (via the mock's `POST /generate`) and fires it as `Authorization: Bearer` on a `GET`. |

A missing `.ppe.yaml` or `.naive.yaml` shows as `-` in the results table (that
arm is not run). A case with only `.authpolicy.yaml` + `.expected` is
ground-truth-only.

## Method cases vs identity cases

The `.expected` keys (first column) mean different things:

- **Method case** (no `.tokens`): each key is an HTTP method. The request varies
  by method (`GET`/`POST`/`DELETE`), no token.
- **Identity case** (has `.tokens`): each key names a token defined in `.tokens`.
  The method is fixed to `GET`; the **identity varies**. `suite.sh` mints one JWT
  per key from the in-cluster mock (`testbed/40-mock-jwt.yaml`, reached on
  loopback via an auto port-forward) and attaches it as a Bearer token.

Only set custom claims in `.tokens` (e.g. `roles`). Overriding a default claim
(`iss`/`aud`/`sub`, set from the mock's env) makes the mock emit a duplicate key;
avoid relying on duplicate-key last-wins across the two JWT stacks.

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
| `cel-id-roles` | Identity case (CEL). JWT `roles` claim: Kuadrant `auth.identity.roles` → PPE `subject.roles` (via `identity/jwt` + `standard` preset). Mapped matches Authorino (admin→allow, guest→deny); naive keeps `auth.identity.roles` → `auth` is not a PPE namespace → deny-all, **including the admin token Authorino allows** (#130 on an allow row, CEL fails loud). |
| `opa-id-roles` | Identity case (OPA), counterpart of `cel-id-roles`. Kuadrant Rego `input.auth.identity.roles` → PPE `input.subject.roles`. Mapped matches Authorino; naive keeps `input.auth.identity.roles` → `input.auth` undefined in PPE → silent deny-all, including admin. The CEL-loud / OPA-silent split, now on the identity dictionary. |

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
./suite.sh 'cel-id-*'              # identity cases (needs the mock; see SETUP.md)

# single case, interactive: start PPE with one policy and curl it yourself
./run.sh cel-req-method            # mapped policy
./run.sh cel-req-method naive      # naive policy (#130)
./run.sh cel-req-method -t         # validate config only
```

`suite.sh` per case: applies the AuthPolicy → waits until enforcement is
actually live (probes the gateway, not just the CR status) → fires at the
gateway → deletes → runs the PPE arms → prints a matrix. Progress is on stderr;
the table is on stdout (`2>/dev/null` for table only).

Four arms per case:

| Column | Policy run | Checked against |
|--------|-----------|-----------------|
| `AUTHORINO` | the `.authpolicy.yaml` on the live gateway | `.expected` (`ok`/`DIFF`) |
| `PPE-MAP` | `.ppe.yaml` (attributes mapped) | `.expected` (`ok`/`DIFF`) |
| `PPE-NAIVE` | `.naive.yaml` (verbatim Kuadrant attrs) | Authorino (`match`, or `#130` = expected divergence) |
| `PPE-COMPAT` | the **same** `.naive.yaml` text + `engine_settings.kuadrant_compat: true` (injected at run time) | Authorino (`ok` = verbatim policy resolved under compat / `FAIL`) |

`PPE-COMPAT` is the payoff arm: the compat pass re-keys the bag into the Kuadrant
Well-Known Attribute vocabulary (see the dictionary table above), so the
unmodified verbatim policy resolves. It should read `ok` on the same rows where
`PPE-NAIVE` shows `#130`. It requires the local-policy build (the published crate
has no `kuadrant_compat` flag — see [`../SETUP.md`](../SETUP.md)). `-` = arm not
present. The suite exits non-zero on any `DIFF` or `FAIL`.

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
