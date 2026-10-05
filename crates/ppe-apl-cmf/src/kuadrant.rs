// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Kuadrant `request.*` compatibility projection (issue #156).
//!
//! Pure producers: given the fully-populated policy bag, return the Kuadrant
//! Well-Known Attribute key/value pairs for the HTTP request. The caller (each
//! per-PDP input builder) inserts these into its engine-specific input; the
//! shared [`AttributeBag`] is never mutated, so native PPE rules and other PDPs
//! are unaffected. An absent source produces no alias, preserving the
//! absent-value (fail-closed) contract.
//!
//! Scope is the RFC 0002 "Request attributes" family only. Gap attributes
//! (`protocol`, `size`) have no PPE source and are deliberately not produced —
//! `size` is Envoy's measured `bytesReceived()` (a Praxis → PPE follow-up), NOT
//! the `content-length` header. `body` / `raw_body` / `context_extensions` are
//! removed from the compat surface. See
//! `docs/brainstorms/2026-10-02-kuadrant-request-attr-mapping-requirements.md`.
//!
//! This is the first vertical slice: only `request.id` is mapped so far
//! (`request.id` → inbound `x-request-id`, with a host request ID fallback). The
//! remaining request-line, header, and derived attributes land in later slices.

use praxis_policy_apl_core::attributes::{AttributeBag, AttributeValue};

/// WKA `request.*` scalar leaves derived from HTTP and host request metadata.
///
/// Scalar only — no header-map entries (those are produced by `request_headers`
/// as literal keys). Leaf names here never contain a dot, so they are safe for
/// the per-PDP dotted-path tree builders.
///
/// Mapped so far:
/// - `request.id` ← inbound `x-request-id`, or PPE `request.request_id` if the
///   header is absent.
pub fn request_aliases(bag: &AttributeBag) -> Vec<(String, AttributeValue)> {
    let mut out: Vec<(String, AttributeValue)> = Vec::new();

    // Kuadrant reads the inbound x-request-id. Use the host's request ID only
    // when the header is absent; neither source changes the shared bag.
    if let Some(v) = bag
        .get("http.request_headers.x-request-id")
        .or_else(|| bag.get("request.request_id"))
    {
        out.push(("request.id".to_owned(), v.clone()));
    }

    out
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used, reason = "tests")]
mod tests {
    use super::*;

    fn pairs(v: &[(String, AttributeValue)]) -> std::collections::HashMap<String, AttributeValue> {
        v.iter().cloned().collect()
    }

    #[test]
    fn request_id_falls_back_to_host_request_id() {
        let mut bag = AttributeBag::new();
        bag.set("request.request_id", "req-abc");
        let m = pairs(&request_aliases(&bag));
        assert_eq!(
            m.get("request.id"),
            Some(&AttributeValue::String("req-abc".into()))
        );
    }

    #[test]
    fn request_id_aliased_from_inbound_header() {
        let mut bag = AttributeBag::new();
        bag.set("http.request_headers.x-request-id", "header-id");
        let m = pairs(&request_aliases(&bag));
        assert_eq!(
            m.get("request.id"),
            Some(&AttributeValue::String("header-id".into()))
        );
    }

    #[test]
    fn request_id_prefers_inbound_header_over_host_request_id() {
        let mut bag = AttributeBag::new();
        bag.set("request.request_id", "host-id");
        bag.set("http.request_headers.x-request-id", "header-id");
        let m = pairs(&request_aliases(&bag));
        assert_eq!(
            m.get("request.id"),
            Some(&AttributeValue::String("header-id".into()))
        );
    }

    #[test]
    fn absent_source_yields_no_alias() {
        let bag = AttributeBag::new();
        assert!(request_aliases(&bag).is_empty());
    }
}
