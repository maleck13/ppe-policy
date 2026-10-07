// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

use std::collections::HashMap;

use limitador::RateLimiter;
use limitador::limit::{Context, Expression, Limit, Namespace, Predicate};
use praxis_policy_core::context::PluginContext;
use praxis_policy_core::error::{PluginError, PluginViolation};
use praxis_policy_core::hooks::{Extensions, HookHandler, PluginResult};
use praxis_policy_core::http_hook::{HttpHook, HttpPayload};
use praxis_policy_core::plugin::{Plugin, PluginConfig};
use tokio::sync::Mutex;

use super::config::RateLimitConfig;

pub(super) struct RateLimit {
    config: PluginConfig,
    namespace: Namespace,
    limiter: RateLimiter,
    check_lock: Mutex<()>,
}

impl RateLimit {
    pub(super) fn new(config: PluginConfig) -> Result<Self, Box<PluginError>> {
        let raw = config.config.clone().ok_or_else(|| {
            PluginError::Config {
                message: format!("plugin '{}': ratelimit config is required", config.name),
            }
            .boxed()
        })?;
        let typed: RateLimitConfig = serde_json::from_value(raw).map_err(|error| {
            PluginError::Config {
                message: format!(
                    "plugin '{}': invalid ratelimit config: {error}",
                    config.name
                ),
            }
            .boxed()
        })?;
        typed
            .validate()
            .map_err(|message| PluginError::Config { message }.boxed())?;

        let namespace: Namespace = typed.namespace.as_str().into();
        let limiter = RateLimiter::new(typed.counter_capacity);
        for (index, entry) in typed.limits.iter().enumerate() {
            let conditions: Vec<Predicate> = entry
                .conditions
                .iter()
                .map(|condition| condition.as_str().try_into())
                .collect::<Result<_, _>>()
                .map_err(|error| {
                    PluginError::Config {
                        message: format!("ratelimit: limits[{index}] invalid condition: {error}"),
                    }
                    .boxed()
                })?;
            let variables: Vec<Expression> = entry
                .variables
                .iter()
                .map(|variable| variable.as_str().try_into())
                .collect::<Result<_, _>>()
                .map_err(|error| {
                    PluginError::Config {
                        message: format!("ratelimit: limits[{index}] invalid variable: {error}"),
                    }
                    .boxed()
                })?;
            if !limiter.add_limit(Limit::new(
                typed.namespace.as_str(),
                entry.max,
                entry.seconds,
                conditions,
                variables,
            )) {
                return Err(PluginError::Config {
                    message: format!("ratelimit: limits[{index}] duplicates an earlier limit"),
                }
                .boxed());
            }
        }

        Ok(Self {
            config,
            namespace,
            limiter,
            check_lock: Mutex::new(()),
        })
    }
}

impl Plugin for RateLimit {
    fn config(&self) -> &PluginConfig {
        &self.config
    }
}

impl HookHandler<HttpHook> for RateLimit {
    async fn handle(
        &self,
        _payload: &HttpPayload,
        extensions: &Extensions,
        _ctx: &mut PluginContext,
    ) -> PluginResult<HttpPayload> {
        let subject_id = extensions
            .security
            .as_ref()
            .and_then(|security| security.subject.as_ref())
            .and_then(|subject| subject.id.as_deref())
            .filter(|id| !id.is_empty());
        let Some(subject_id) = subject_id else {
            return PluginResult::deny(PluginViolation::new(
                "ratelimit.no_identity",
                "no resolved identity to rate limit",
            ));
        };
        let http_method = extensions
            .http
            .as_ref()
            .and_then(|http| http.method.as_deref());
        let Some(http_method) = http_method else {
            return PluginResult::deny(PluginViolation::new(
                "ratelimit.no_http_method",
                "HTTP method is unavailable to the rate limiter",
            ));
        };

        let values = HashMap::from([
            ("subject_id".to_owned(), subject_id.to_owned()),
            ("http_method".to_owned(), http_method.to_owned()),
        ]);
        let context: Context<'_> = values.into();
        // Limitador's in-memory check and update are separate operations. Serialize them
        // across this plugin instance so concurrent requests cannot exceed the limit.
        let _guard = self.check_lock.lock().await;
        match self
            .limiter
            .check_rate_limited_and_update(&self.namespace, &context, 1, false)
        {
            Ok(result) if result.limited => PluginResult::deny(
                PluginViolation::new("ratelimit.exceeded", "request rate limit exceeded")
                    .with_proto_error_code(429),
            ),
            Ok(_) => PluginResult::allow(),
            Err(error) => {
                tracing::error!(%error, "ratelimit: Limitador check failed");
                PluginResult::deny(PluginViolation::new(
                    "ratelimit.check_failed",
                    "request rate limit check failed",
                ))
            },
        }
    }
}
