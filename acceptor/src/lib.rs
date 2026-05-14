//! Tickets acceptor.
//!
//! On startup: persists the bearer token (passed via initial_state) into the
//! shared store, binds the listen socket.
//! On each TCP connection: spawns a per-connection ticket-handler, transfers
//! the connection.

#![no_std]
extern crate alloc;

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use packr_guest::{export, import, pack_types, GraphValue, Value};

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
            spawn: func(manifest: string, init-bytes: option<list<u8>>, wasm-bytes: option<list<u8>>) -> result<string, string>,
            stop-child: func(child-id: string) -> result<_, string>,
        }
        theater:simple/rpc {
            call: func(actor-id: string, function: string, params: value, options: value) -> value,
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
    init_bytes: Option<Vec<u8>>,
    wasm_bytes: Option<Vec<u8>>,
) -> Result<String, String>;

#[import(module = "theater:simple/supervisor", name = "stop-child")]
fn supervisor_stop_child(child_id: String) -> Result<(), String>;

#[import(module = "theater:simple/store", name = "store-at-label")]
fn store_store_at_label(store_id: String, label: String, content: Vec<u8>) -> Result<String, String>;

#[import(module = "theater:simple/rpc", name = "call")]
fn rpc_call(actor_id: String, function: String, params: Value, options: Value) -> Value;

const LISTEN_ADDR: &str = "127.0.0.1:8443";
const HANDLER_MANIFEST: &str =
    "/home/colin/work/actors/tickets/ticket-handler/manifest.toml";

const STORE_ID: &str = "tickets";
const BEARER_TOKEN_LABEL: &str = "api-bearer-token";

#[export(name = "theater:simple/actor.init")]
fn init(state: Value) -> Result<(AcceptorState, ()), String> {
    log(String::from("[tickets-acceptor] init"));

    // initial_state is the bearer token (single line). Persist it to the
    // shared store so per-connection handlers can fetch it on demand.
    let bearer_token = match state {
        Value::String(s) if !s.is_empty() => s,
        _ => {
            return Err(String::from(
                "acceptor needs initial_state = \"<bearer-token>\" in manifest",
            ))
        }
    };
    store_store_at_label(
        String::from(STORE_ID),
        String::from(BEARER_TOKEN_LABEL),
        bearer_token.into_bytes(),
    )
    .map_err(|e| format!("persist bearer token failed: {}", e))?;

    let listener_id = tcp_listen(String::from(LISTEN_ADDR))
        .map_err(|e| format!("listen failed: {}", e))?;
    log(format!(
        "[tickets-acceptor] HTTP listening on {} (id={})",
        LISTEN_ADDR, listener_id
    ));

    Ok((
        AcceptorState {
            listener_id,
            handler_manifest: String::from(HANDLER_MANIFEST),
        },
        (),
    ))
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
    let handler_id = supervisor_spawn(state.handler_manifest.clone(), None, None)
        .map_err(|e| format!("spawn handler failed: {}", e))?;

    let init_params = Value::Tuple(alloc::vec![]);
    let _ = rpc_call(
        handler_id.clone(),
        String::from("theater:simple/actor.init"),
        init_params,
        Value::Tuple(alloc::vec![]),
    );

    if let Err(e) = tcp_transfer(connection_id.to_string(), handler_id.clone()) {
        let _ = supervisor_stop_child(handler_id);
        return Err(format!("transfer failed: {}", e));
    }
    Ok(())
}
