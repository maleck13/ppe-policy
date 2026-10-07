// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! In-process proof that an APL route runs the embedded Limitador plugin.

#![allow(
    missing_docs,
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "integration tests inspect the rate-limit decision"
)]

use std::sync::Arc;

use praxis_policy_apl_runtime::{AplOptions, register_apl};
use praxis_policy_builtins::plugins::ratelimit::{KIND, RateLimitFactory};
use praxis_policy_core::cmf::constants::{ENTITY_HTTP, ENTITY_NAME_GLOBAL};
use praxis_policy_core::engine::PolicyEngine;
use praxis_policy_core::error::PluginError;
use praxis_policy_core::extensions::{
    Extensions, HttpExtension, MetaExtension, SecurityExtension, SubjectExtension,
};
use praxis_policy_core::factory::PluginFactory as _;
use praxis_policy_core::http_hook::{HOOK_HTTP_REQUEST, HttpHook, HttpPayload};
use praxis_policy_core::plugin::PluginConfig;

const POLICY: &str = r#"
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
"#;

async fn engine() -> Arc<PolicyEngine> {
    let manager = Arc::new(PolicyEngine::default());
    manager.register_factory(KIND, Box::new(RateLimitFactory));
    register_apl(&manager, AplOptions::in_process());
    manager
        .load_config_yaml(POLICY)
        .expect("rate-limit config loads");
    manager
        .initialize()
        .await
        .expect("rate limiter initializes");
    manager
}

fn request(subject_id: Option<&str>, method: Option<&str>) -> Extensions {
    Extensions {
        meta: Some(Arc::new(MetaExtension {
            entity_type: Some(ENTITY_HTTP.to_owned()),
            entity_name: Some(ENTITY_NAME_GLOBAL.to_owned()),
            ..Default::default()
        })),
        http: Some(Arc::new(HttpExtension {
            method: method.map(str::to_owned),
            path: Some("/toys".to_owned()),
            ..Default::default()
        })),
        security: Some(Arc::new(SecurityExtension {
            subject: subject_id.map(|id| SubjectExtension {
                id: Some(id.to_owned()),
                ..Default::default()
            }),
            ..Default::default()
        })),
        ..Default::default()
    }
}

async fn verdict(
    manager: &PolicyEngine,
    subject_id: Option<&str>,
    method: Option<&str>,
) -> (bool, Option<(String, Option<i64>)>) {
    let (result, _background) = manager
        .invoke_named::<HttpHook>(
            HOOK_HTTP_REQUEST,
            HttpPayload,
            request(subject_id, method),
            None,
        )
        .await;
    (
        result.continue_processing,
        result.violation.map(|v| (v.code, v.proto_error_code)),
    )
}

#[allow(clippy::print_stdout, reason = "show decisions in the in-process demo")]
fn show_verdict(label: &str, (allowed, violation): &(bool, Option<(String, Option<i64>)>)) {
    if *allowed {
        println!("{label}: ALLOW");
    } else if let Some((code, Some(status))) = violation {
        println!("{label}: DENY {code} (proto_error_code={status})");
    } else {
        println!("{label}: DENY {violation:?}");
    }
}

#[tokio::test]
async fn counts_alice_and_bob_independently_and_returns_429() {
    let manager = engine().await;

    // POST does not match either GET limit and must leave Alice's balance alone.
    let post = verdict(&manager, Some("alice"), Some("POST")).await;
    show_verdict("alice POST", &post);
    assert!(post.0);
    for number in 1..=5 {
        let result = verdict(&manager, Some("alice"), Some("GET")).await;
        show_verdict(&format!("alice GET #{number}"), &result);
        assert!(result.0);
    }
    for number in 1..=2 {
        let result = verdict(&manager, Some("bob"), Some("GET")).await;
        show_verdict(&format!("bob GET #{number}"), &result);
        assert!(result.0);
    }

    let alice_denied = verdict(&manager, Some("alice"), Some("GET")).await;
    show_verdict("alice GET #6", &alice_denied);
    assert_eq!(
        alice_denied,
        (false, Some(("ratelimit.exceeded".to_owned(), Some(429))))
    );
    let bob_denied = verdict(&manager, Some("bob"), Some("GET")).await;
    show_verdict("bob GET #3", &bob_denied);
    assert_eq!(
        bob_denied,
        (false, Some(("ratelimit.exceeded".to_owned(), Some(429))))
    );
}

#[tokio::test]
async fn missing_identity_or_http_method_denies_before_the_counter() {
    let manager = engine().await;
    assert_eq!(
        verdict(&manager, None, Some("GET")).await.1,
        Some(("ratelimit.no_identity".to_owned(), None))
    );
    assert_eq!(
        verdict(&manager, Some("alice"), None).await.1,
        Some(("ratelimit.no_http_method".to_owned(), None))
    );
    assert!(verdict(&manager, Some("alice"), Some("GET")).await.0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_requests_do_not_exceed_the_in_memory_limit() {
    let manager = engine().await;
    let mut tasks = Vec::new();
    for _ in 0..20 {
        let manager = Arc::clone(&manager);
        tasks.push(tokio::spawn(async move {
            verdict(&manager, Some("alice"), Some("GET")).await.0
        }));
    }
    let mut admitted = 0;
    for task in tasks {
        admitted += usize::from(task.await.expect("request task completes"));
    }
    assert_eq!(admitted, 5);
}

#[test]
fn malformed_condition_fails_during_plugin_construction() {
    let config = PluginConfig {
        name: "app-ratelimit".to_owned(),
        kind: KIND.to_owned(),
        config: Some(serde_json::json!({
            "namespace": "toystore",
            "limits": [{
                "max": 5,
                "seconds": 60,
                "conditions": ["subject_id =="],
            }],
        })),
        ..Default::default()
    };
    let error = RateLimitFactory
        .create(&config)
        .err()
        .expect("malformed CEL must fail at construction");
    assert!(matches!(*error, PluginError::Config { .. }));
}
