<!--
SPDX-License-Identifier: Apache-2.0
Copyright (c) 2026 Praxis Contributors
-->

# Authorino reference fixtures (Tier 1)

Ground truth for the Kuadrant `request.*` compatibility differential (issue
#156). Each `request/<attr>.json` pins what Authorino decides for a verbatim
Kuadrant predicate, so the in-process differential (`src/authorino.rs`, Tier 2)
can assert PPE's compat path produces the same decision.

## Schema

```json
{
  "attribute": "request.id",
  "status": "Mapped",                     // Mapped | Gap
  "request": { "method": "...", "path": "...", "id": "...", "headers": {} },
  "predicate_cel": "request.id == \"req-abc\"",
  "predicate_opa": "package t\nallow if { input.request.id == \"req-abc\" }\n",
  "authorino": { "decision": "allow", "reference": "..." },
  "expected": "allow"                     // the decision PPE must produce
}
```

Both `authorino.decision` and `expected` are `allow` or `deny`. Divergence is
**derived** (`expected != authorino.decision`), never a sentinel:

- **Mapped** rows: `expected == authorino.decision` — compat holds.
- **Gap** rows: `expected != authorino.decision` — PPE diverges (for the
  fail-open direction: Authorino `deny`, PPE `allow`).

Mapped rows' `authorino.decision` is captured from the dual-gateway spike
(Tier 3) where available; a row that is value-deterministic (like `request.id`)
may be reasoned with a `reference` until the Tier 3 run confirms it. There is no
`pending_capture` skip — every fixture must carry an `authorino.decision`.

## Scope so far

Vertical slice: `request.id` only. Remaining request-line / header / derived
attributes land as further fixtures.
