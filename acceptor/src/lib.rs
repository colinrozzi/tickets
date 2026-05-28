//! Tickets acceptor.
//!
//! On startup: parses the JSON `initial_state` config, persists the
//! tickets API bearer token + inbox API endpoint + inbox bearer token into
//! the shared store under labels, then binds the listen socket.
//!
//! On each TCP connection: spawns a per-connection ticket-handler (using
//! the handler-manifest reference from `initial_state`) and transfers
//! the connection.
//!
//! Expected `initial_state` shape (single JSON string):
//!   {"api_token":        "<tickets bearer>",
//!    "inbox_api":        "host:port",
//!    "inbox_token":      "<inbox bearer>",
//!    "handler_manifest": "<file path | https:// | store:// reference>"}
//!
//! `handler_manifest` is whatever `theater::utils::resolve_reference` will
//! accept: a local file path for dev, an https URL for a released asset,
//! or a store-content reference. The acceptor passes it through verbatim
//! to `supervisor.spawn` per connection.

#![no_std]
extern crate alloc;

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use packr_guest::{export, import, pack_types, GraphValue, Value};
use serde::Deserialize;

packr_guest::setup_guest!();

#[derive(Clone, GraphValue)]
#[graph(crate = "packr_guest::composite_abi")]
pub struct AcceptorState {
    pub listener_id: String,
    pub handler_manifest: String,
}

pack_types! {
    imports {
        theater:simple/runtime {
            log: func(msg: string),
        }
        theater:simple/tcp {
            listen: func(address: string) -> result<string, string>,
            transfer: func(connection-id: string, target-actor: string) -> result<_, string>,
        }
        theater:simple/supervisor {
            spawn: func(manifest: string, init-state: option<value>, wasm-bytes: option<list<u8>>) -> result<string, string>,
            stop-child: func(child-id: string) -> result<_, string>,
        }
        theater:simple/store {
            store-at-label: func(store-id: string, label: string, content: list<u8>) -> result<string, string>,
        }
    }
    exports {
        theater:simple/actor.init: func(state: value) -> result<acceptor-state, string>,
        theater:simple/tcp-client.handle-connection: func(state: acceptor-state, connection-id: string) -> result<acceptor-state, string>,
    }
}

#[import(module = "theater:simple/runtime", name = "log")]
fn log(msg: String);

#[import(module = "theater:simple/tcp", name = "listen")]
fn tcp_listen(address: String) -> Result<String, String>;

#[import(module = "theater:simple/tcp", name = "transfer")]
fn tcp_transfer(connection_id: String, target_actor: String) -> Result<(), String>;

#[import(module = "theater:simple/supervisor", name = "spawn")]
fn supervisor_spawn(
    manifest: String,
    init_state: Option<Value>,
    wasm_bytes: Option<Vec<u8>>,
) -> Result<String, String>;

#[import(module = "theater:simple/supervisor", name = "stop-child")]
fn supervisor_stop_child(child_id: String) -> Result<(), String>;

#[import(module = "theater:simple/store", name = "store-at-label")]
fn store_store_at_label(store_id: String, label: String, content: Vec<u8>) -> Result<String, String>;

const LISTEN_ADDR: &str = "127.0.0.1:8443";

const STORE_ID: &str = "tickets";
const BEARER_TOKEN_LABEL: &str = "api-bearer-token";
const INBOX_API_LABEL: &str = "inbox-api";
const INBOX_TOKEN_LABEL: &str = "inbox-token";

#[derive(Deserialize)]
struct Config {
    /// Bearer token clients send to the tickets HTTP API.
    api_token: String,
    /// Host:port of the inbox HTTP API (e.g. "mail.colinrozzi.com:443"). The
    /// handler uses this to POST notification emails when tickets change.
    inbox_api: String,
    /// Bearer token the handler presents when calling the inbox API.
    inbox_token: String,
    /// Reference to the ticket-handler manifest, passed to
    /// `supervisor.spawn` on each new connection. Accepts anything
    /// `theater::utils::resolve_reference` resolves: a file path, an
    /// https:// URL, or a store:// reference. Set per-deploy so the
    /// acceptor is portable across dev + release.
    handler_manifest: String,
}

#[export(name = "theater:simple/actor.init")]
fn init(state: Value) -> Result<(AcceptorState, ()), String> {
    log(String::from("[tickets-acceptor] init"));

    let raw = match state {
        Value::String(s) if !s.is_empty() => s,
        _ => {
            return Err(String::from(
                "acceptor: initial_state must be a JSON config string \
                 with {api_token, inbox_api, inbox_token, handler_manifest}",
            ))
        }
    };
    let cfg: Config = serde_json::from_str(&raw)
        .map_err(|e| format!("acceptor: bad initial_state JSON: {}", e))?;
    if cfg.api_token.is_empty() {
        return Err(String::from("acceptor: api_token must be non-empty"));
    }
    if cfg.inbox_api.is_empty() {
        return Err(String::from("acceptor: inbox_api must be non-empty"));
    }
    if cfg.inbox_token.is_empty() {
        return Err(String::from("acceptor: inbox_token must be non-empty"));
    }
    if cfg.handler_manifest.is_empty() {
        return Err(String::from(
            "acceptor: handler_manifest must be non-empty",
        ));
    }

    persist(BEARER_TOKEN_LABEL, cfg.api_token)?;
    persist(INBOX_API_LABEL, cfg.inbox_api)?;
    persist(INBOX_TOKEN_LABEL, cfg.inbox_token)?;

    let listener_id = tcp_listen(String::from(LISTEN_ADDR))
        .map_err(|e| format!("listen failed: {}", e))?;
    log(format!(
        "[tickets-acceptor] HTTP listening on {} (id={}); handler_manifest={}",
        LISTEN_ADDR, listener_id, cfg.handler_manifest
    ));

    Ok((
        AcceptorState {
            listener_id,
            handler_manifest: cfg.handler_manifest,
        },
        (),
    ))
}

fn persist(label: &str, value: String) -> Result<(), String> {
    store_store_at_label(
        String::from(STORE_ID),
        String::from(label),
        value.into_bytes(),
    )
    .map(|_| ())
    .map_err(|e| format!("persist {} failed: {}", label, e))
}

#[export(name = "theater:simple/tcp-client.handle-connection")]
fn handle_connection(
    state: AcceptorState,
    connection_id: String,
) -> Result<(AcceptorState, ()), String> {
    // Always return Ok regardless of what happens inside — a single failing
    // connection (e.g. client closed before transfer) must not kill the
    // acceptor. Log + clean up + carry on.
    if let Err(e) = try_handle_connection(&state, &connection_id) {
        log(format!(
            "[tickets-acceptor] handle-connection failed (conn={}): {}",
            connection_id, e
        ));
    }
    Ok((state, ()))
}

fn try_handle_connection(state: &AcceptorState, connection_id: &str) -> Result<(), String> {
    // Post theater PRs #58-60, supervisor.spawn auto-calls the child's
    // actor.init before returning the id. We pass None for init-state so
    // the handler's manifest initial_state (none in our case) is used;
    // the handler's init ignores its arg anyway.
    let handler_id = supervisor_spawn(state.handler_manifest.clone(), None, None)
        .map_err(|e| format!("spawn handler failed: {}", e))?;

    if let Err(e) = tcp_transfer(connection_id.to_string(), handler_id.clone()) {
        let _ = supervisor_stop_child(handler_id);
        return Err(format!("transfer failed: {}", e));
    }
    Ok(())
}
