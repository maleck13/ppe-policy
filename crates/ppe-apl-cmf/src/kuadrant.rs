// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

// Kuadrant compatibility bridge — issue #130, Approach A.
//
// Every other module in this crate bridges a *typed* praxis-policy-core
// extension into the flat bag. This one is different: it is a bag → bag pass
// that runs AFTER the typed bridges and re-keys values that are already in the
// bag under the Kuadrant Well-Known Attribute (WKA) vocabulary, so an
// unmodified Kuadrant AuthPolicy predicate (CEL or Rego, written against the
// WKA names) resolves the same value it would on Authorino.
//
// Why a re-key pass and not a typed bridge: the WKA→PPE mapping is defined over
// the PPE *bag* names (`http.method` → `request.method`), not over the typed
// extension shapes. Reading the assembled bag keeps the mapping in one place,
// avoids duplicating every typed extractor, and inherits the capability model
// for free — a value stripped by capability filtering was never written to the
// bag, so its WKA alias is never created either (fail-closed is preserved).
//
// This realises the run-verbatim ("no policy rewrite") half of the #130
// compatibility work. The complementary ahead-of-time transpiler lives
// out-of-tree. See docs/proposals/00130_kuadrant-adapter-compatibility.md and
// the field-by-field mapping in 00133.
//
// Namespace note — the `request.*` collision:
//   PPE's native `request.*` is trace/env metadata (BAG_REQUEST_PREFIX:
//   request_id, timestamp, trace_id, ...). Kuadrant's `request.*` is the HTTP
//   request (method, path, host, ...). The leaf names are DISJOINT, so this
//   pass adds the HTTP leaves alongside any trace leaves under the shared
//   `request` root; both resolve. Mixing the two under one root is a hygiene
//   trade-off accepted only under the opt-in compatibility flag.
//
// What is mapped (the runtime-observable subset the differential suite covers):
//   http.method|path|host|scheme      → request.<leaf>
//                                        context.request.http.<leaf>   (OPA dep. path)
//   http.request_headers.<name>       → request.headers.<name>
//                                        context.request.http.headers.<name>
//   subject.id                        → auth.identity.sub
//   subject.roles                     → auth.identity.roles
//   claim.<name>                      → auth.identity.<name>
//
// Not mapped (no PPE source — a documented gap in 00133): auth.metadata.*,
// source.*, destination.*, connection.*, request.body/query/size.

use praxis_policy_apl_core::{AttributeBag, AttributeValue};

use crate::constants::{
    BAG_CLAIM_PREFIX, BAG_HTTP_HOST, BAG_HTTP_METHOD, BAG_HTTP_PATH,
    BAG_HTTP_REQUEST_HEADERS_PREFIX, BAG_HTTP_SCHEME, BAG_SUBJECT_ID, BAG_SUBJECT_ROLES,
};

/// The four request-line leaves, paired as (PPE bag key, WKA leaf name).
const REQUEST_LINE: &[(&str, &str)] = &[
    (BAG_HTTP_METHOD, "method"),
    (BAG_HTTP_PATH, "path"),
    (BAG_HTTP_HOST, "host"),
    (BAG_HTTP_SCHEME, "scheme"),
];

/// Add Kuadrant WKA aliases for every PPE value the bag already carries.
///
/// Pure and idempotent: it only reads existing keys and writes alias keys, so
/// running it twice yields the same bag. Absent sources produce no aliases,
/// preserving the absent-value (fail-closed) contract.
///
/// Run this AFTER the typed bridges (e.g. via [`crate::BagBuilder::with_kuadrant_compat`]);
/// on an empty bag it is a no-op.
pub fn apply_kuadrant_compat(bag: &mut AttributeBag) {
    // Collect first, then write: `bag.iter()`/`bag.get()` borrow immutably
    // while we build the alias list; the writes happen after those borrows end.
    let mut aliases: Vec<(String, AttributeValue)> = Vec::new();

    // Request line → WKA `request.*` and the OPA-deprecated
    // `context.request.http.*` path (Authorino's AuthJSON still accepts it).
    for (ppe_key, leaf) in REQUEST_LINE {
        if let Some(v) = bag.get(ppe_key) {
            aliases.push((format!("request.{leaf}"), v.clone()));
            aliases.push((format!("context.request.http.{leaf}"), v.clone()));
        }
    }

    // Request headers → WKA `request.headers.*` and the deprecated path.
    // Both PPE and WKA lowercase header names, so the leaf carries over as-is.
    for (key, v) in bag.iter() {
        if let Some(name) = key.strip_prefix(BAG_HTTP_REQUEST_HEADERS_PREFIX) {
            aliases.push((format!("request.headers.{name}"), v.clone()));
            aliases.push((format!("context.request.http.headers.{name}"), v.clone()));
        }
    }

    // Identity → WKA `auth.identity.*`. `subject.id`/`subject.roles` are the
    // standard-mapper landing spots; raw `claim.*` covers everything else.
    if let Some(v) = bag.get(BAG_SUBJECT_ID) {
        aliases.push(("auth.identity.sub".to_owned(), v.clone()));
    }
    if let Some(v) = bag.get(BAG_SUBJECT_ROLES) {
        aliases.push(("auth.identity.roles".to_owned(), v.clone()));
    }
    for (key, v) in bag.iter() {
        if let Some(name) = key.strip_prefix(BAG_CLAIM_PREFIX) {
            aliases.push((format!("auth.identity.{name}"), v.clone()));
        }
    }

    for (key, value) in aliases {
        bag.set(key, value);
    }
}

#[cfg(test)]
#[allow(
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::print_stderr,
    clippy::print_stdout,
    clippy::unwrap_used,
    reason = "tests"
)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn request_line_aliased_to_wka_and_deprecated_path() {
        let mut bag = AttributeBag::new();
        bag.set(BAG_HTTP_METHOD, "POST");
        bag.set(BAG_HTTP_PATH, "/toys");

        apply_kuadrant_compat(&mut bag);

        // WKA CEL form.
        assert_eq!(bag.get_string("request.method"), Some("POST"));
        assert_eq!(bag.get_string("request.path"), Some("/toys"));
        // OPA-deprecated AuthJSON path.
        assert_eq!(bag.get_string("context.request.http.method"), Some("POST"));
        assert_eq!(bag.get_string("context.request.http.path"), Some("/toys"));
        // Original PPE key is untouched.
        assert_eq!(bag.get_string("http.method"), Some("POST"));
    }

    #[test]
    fn absent_source_produces_no_alias() {
        let mut bag = AttributeBag::new();
        // No http.* keys set.
        apply_kuadrant_compat(&mut bag);
        assert!(!bag.contains("request.method"));
        assert!(!bag.contains("context.request.http.method"));
    }

    #[test]
    fn request_headers_aliased_lowercased() {
        let mut bag = AttributeBag::new();
        bag.set("http.request_headers.authorization", "Bearer xyz");

        apply_kuadrant_compat(&mut bag);

        assert_eq!(
            bag.get_string("request.headers.authorization"),
            Some("Bearer xyz")
        );
        assert_eq!(
            bag.get_string("context.request.http.headers.authorization"),
            Some("Bearer xyz")
        );
    }

    #[test]
    fn identity_roles_aliased_to_auth_identity() {
        let mut bag = AttributeBag::new();
        bag.set(BAG_SUBJECT_ID, "mock-user");
        bag.set(
            BAG_SUBJECT_ROLES,
            HashSet::from(["admin".to_owned(), "guest".to_owned()]),
        );
        bag.set("claim.email", "a@b.c");

        apply_kuadrant_compat(&mut bag);

        assert_eq!(bag.get_string("auth.identity.sub"), Some("mock-user"));
        // StringSet carries over so Rego `input.auth.identity.roles[_]` and CEL
        // `auth.identity.roles.exists(...)` both work.
        assert!(bag.set_contains("auth.identity.roles", "admin"));
        assert_eq!(bag.get_string("auth.identity.email"), Some("a@b.c"));
    }

    #[test]
    fn idempotent() {
        let mut bag = AttributeBag::new();
        bag.set(BAG_HTTP_METHOD, "GET");
        apply_kuadrant_compat(&mut bag);
        let len_once = bag.len();
        apply_kuadrant_compat(&mut bag);
        assert_eq!(bag.len(), len_once);
        assert_eq!(bag.get_string("request.method"), Some("GET"));
    }
}
