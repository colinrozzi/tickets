//! Tickets handler: per-connection HTTP handler.
//!
//! Receives one HTTP request, routes it, reads/writes ticket state from the
//! shared store, returns JSON, closes the connection, and shuts itself down.
//!
//! Routes:
//!   GET  /v1/tickets                                    → list (optional ?status=, ?assignee=)
//!   POST /v1/tickets                                    → create
//!   GET  /v1/tickets/<id>                               → show one
//!   POST /v1/tickets/<id>/status                        → set status

#![no_std]
extern crate alloc;

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use packr_guest::{export, import, pack_types, GraphValue, Value};
use serde::{Deserialize, Serialize};

packr_guest::setup_guest!();

#[derive(Clone, GraphValue)]
#[graph(crate = "packr_guest::composite_abi")]
pub struct HandlerState {}

pack_types! {
    imports {
        theater:simple/runtime {
            log: func(msg: string),
            shutdown: func(data: option<list<u8>>) -> result<_, string>,
        }
        theater:simple/tcp {
            receive: func(connection-id: string, max-bytes: u32) -> result<list<u8>, string>,
            send: func(connection-id: string, data: list<u8>) -> result<u64, string>,
            close: func(connection-id: string) -> result<_, string>,
        }
        theater:simple/store {
            get: func(store-id: string, content-ref: string) -> result<list<u8>, string>,
            get-by-label: func(store-id: string, label: string) -> result<option<string>, string>,
            store-at-label: func(store-id: string, label: string, content: list<u8>) -> result<string, string>,
        }
        theater:simple/timer {
            now: func() -> u64,
        }
    }
    exports {
        theater:simple/actor.init: func(state: value) -> result<handler-state, string>,
        theater:simple/tcp-client.handle-connection-transfer: func(state: handler-state, connection-id: string) -> result<handler-state, string>,
    }
}

#[import(module = "theater:simple/runtime", name = "log")]
fn log(msg: String);

#[import(module = "theater:simple/runtime", name = "shutdown")]
fn shutdown(data: Option<Vec<u8>>) -> Result<(), String>;

#[import(module = "theater:simple/tcp", name = "receive")]
fn tcp_receive(connection_id: String, max_bytes: u32) -> Result<Vec<u8>, String>;

#[import(module = "theater:simple/tcp", name = "send")]
fn tcp_send(connection_id: String, data: Vec<u8>) -> Result<u64, String>;

#[import(module = "theater:simple/tcp", name = "close")]
fn tcp_close(connection_id: String) -> Result<(), String>;

#[import(module = "theater:simple/store", name = "get")]
fn store_get(store_id: String, content_ref: String) -> Result<Vec<u8>, String>;

#[import(module = "theater:simple/store", name = "get-by-label")]
fn store_get_by_label(store_id: String, label: String) -> Result<Option<String>, String>;

#[import(module = "theater:simple/store", name = "store-at-label")]
fn store_store_at_label(store_id: String, label: String, content: Vec<u8>) -> Result<String, String>;

#[import(module = "theater:simple/timer", name = "now")]
fn timer_now() -> u64;

const STORE_ID: &str = "tickets";
const BEARER_TOKEN_LABEL: &str = "api-bearer-token";
const TICKETS_LIST_LABEL: &str = "tickets-list";

// ============================================================================
// Data types
// ============================================================================

#[derive(Serialize, Deserialize, Clone)]
struct Ticket {
    id: u64,
    title: String,
    body: String,
    reporter: String,
    assignee: String,
    status: String,
    created_at: u64,
}

#[derive(Deserialize)]
struct NewTicketRequest {
    title: String,
    body: String,
    reporter: String,
    assignee: String,
}

#[derive(Deserialize)]
struct SetStatusRequest {
    status: String,
}

#[derive(Serialize)]
struct TicketsList {
    tickets: Vec<Ticket>,
}

const VALID_STATUSES: &[&str] = &["open", "in-progress", "done", "closed"];

// ============================================================================
// Actor entry points
// ============================================================================

#[export(name = "theater:simple/actor.init")]
fn init(_state: Value) -> Result<(HandlerState, ()), String> {
    Ok((HandlerState {}, ()))
}

#[export(name = "theater:simple/tcp-client.handle-connection-transfer")]
fn handle_connection_transfer(
    state: HandlerState,
    connection_id: String,
) -> Result<(HandlerState, ()), String> {
    let request = tcp_receive(connection_id.clone(), 65536).unwrap_or_default();
    let response = route(&request);

    if let Err(e) = tcp_send(connection_id.clone(), response) {
        log(format!("[tickets-handler] send failed: {}", e));
    }
    let _ = tcp_close(connection_id);
    let _ = shutdown(None);

    Ok((state, ()))
}

// ============================================================================
// Routing
// ============================================================================

fn route(request: &[u8]) -> Vec<u8> {
    let request_str = match core::str::from_utf8(request) {
        Ok(s) => s,
        Err(_) => return http_response(400, br#"{"error":"non-utf8 request"}"#.to_vec()),
    };

    // Auth
    if !check_auth(request_str) {
        return http_response(401, br#"{"error":"unauthorized"}"#.to_vec());
    }

    let request_line = request_str.lines().next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let raw_path = parts.next().unwrap_or("");
    let (path, query) = match raw_path.split_once('?') {
        Some((p, q)) => (p, q),
        None => (raw_path, ""),
    };

    match (method, path) {
        ("GET", "/v1/tickets") => handle_list(query),
        ("POST", "/v1/tickets") => handle_create(request_str),
        ("GET", p) if p.starts_with("/v1/tickets/") => {
            let rest = &p["/v1/tickets/".len()..];
            if rest.is_empty() || rest.contains('/') {
                return http_response(404, br#"{"error":"not found"}"#.to_vec());
            }
            handle_show(rest)
        }
        ("POST", p) if p.starts_with("/v1/tickets/") && p.ends_with("/status") => {
            let id_str = &p["/v1/tickets/".len()..p.len() - "/status".len()];
            if id_str.is_empty() || id_str.contains('/') {
                return http_response(404, br#"{"error":"not found"}"#.to_vec());
            }
            handle_set_status(id_str, request_str)
        }
        _ => http_response(404, br#"{"error":"not found"}"#.to_vec()),
    }
}

fn check_auth(request_str: &str) -> bool {
    let stored = match load_label_as_string(BEARER_TOKEN_LABEL) {
        Ok(t) => t,
        Err(_) => return false,
    };
    let bearer = match extract_bearer(request_str) {
        Some(b) => b,
        None => return false,
    };
    bearer == stored
}

fn load_label_as_string(label: &str) -> Result<String, String> {
    let content_ref = store_get_by_label(String::from(STORE_ID), String::from(label))
        .map_err(|e| format!("{} lookup failed: {}", label, e))?
        .ok_or_else(|| format!("{} not set", label))?;
    let bytes = store_get(String::from(STORE_ID), content_ref)
        .map_err(|e| format!("{} get failed: {}", label, e))?;
    String::from_utf8(bytes).map_err(|_| format!("{} is not valid UTF-8", label))
}

fn extract_bearer(request_str: &str) -> Option<String> {
    for line in request_str.lines() {
        let lower: String = line.chars().map(|c| c.to_ascii_lowercase()).collect();
        if let Some(rest) = lower.strip_prefix("authorization:") {
            let rest = rest.trim();
            if let Some(token) = rest.strip_prefix("bearer ") {
                return Some(token.to_string());
            }
        }
    }
    None
}

// ============================================================================
// Handlers
// ============================================================================

fn handle_list(query: &str) -> Vec<u8> {
    let (status_filter, assignee_filter) = parse_query(query);
    let all = load_tickets();
    let filtered: Vec<Ticket> = all
        .into_iter()
        .filter(|t| match &status_filter {
            Some(s) => &t.status == s,
            None => true,
        })
        .filter(|t| match &assignee_filter {
            Some(a) => &t.assignee == a,
            None => true,
        })
        .collect();
    let body = serde_json::to_vec(&TicketsList { tickets: filtered }).unwrap_or_default();
    http_response(200, body)
}

fn handle_show(id_str: &str) -> Vec<u8> {
    let id: u64 = match id_str.parse() {
        Ok(n) => n,
        Err(_) => return http_response(400, br#"{"error":"invalid ticket id"}"#.to_vec()),
    };
    let all = load_tickets();
    match all.into_iter().find(|t| t.id == id) {
        Some(t) => {
            let body = serde_json::to_vec(&t).unwrap_or_default();
            http_response(200, body)
        }
        None => http_response(404, br#"{"error":"ticket not found"}"#.to_vec()),
    }
}

fn handle_create(request_str: &str) -> Vec<u8> {
    let body = match request_str.find("\r\n\r\n") {
        Some(i) => &request_str[i + 4..],
        None => return http_response(400, br#"{"error":"missing body"}"#.to_vec()),
    };

    let req: NewTicketRequest = match serde_json::from_str(body) {
        Ok(r) => r,
        Err(e) => {
            let msg = format!(r#"{{"error":"bad request body: {}"}}"#, e);
            return http_response(400, msg.into_bytes());
        }
    };
    if req.title.is_empty() || req.reporter.is_empty() || req.assignee.is_empty() {
        return http_response(
            400,
            br#"{"error":"title, reporter, and assignee are required"}"#.to_vec(),
        );
    }

    let mut all = load_tickets();
    let next_id = all.iter().map(|t| t.id).max().unwrap_or(0) + 1;
    let new = Ticket {
        id: next_id,
        title: req.title,
        body: req.body,
        reporter: req.reporter,
        assignee: req.assignee,
        status: String::from("open"),
        created_at: timer_now(),
    };
    all.push(new.clone());
    save_tickets(&all);

    let body = serde_json::to_vec(&new).unwrap_or_default();
    http_response(201, body)
}

fn handle_set_status(id_str: &str, request_str: &str) -> Vec<u8> {
    let id: u64 = match id_str.parse() {
        Ok(n) => n,
        Err(_) => return http_response(400, br#"{"error":"invalid ticket id"}"#.to_vec()),
    };

    let body = match request_str.find("\r\n\r\n") {
        Some(i) => &request_str[i + 4..],
        None => return http_response(400, br#"{"error":"missing body"}"#.to_vec()),
    };

    let req: SetStatusRequest = match serde_json::from_str(body) {
        Ok(r) => r,
        Err(e) => {
            let msg = format!(r#"{{"error":"bad request body: {}"}}"#, e);
            return http_response(400, msg.into_bytes());
        }
    };

    if !VALID_STATUSES.iter().any(|s| *s == req.status) {
        let msg = format!(
            r#"{{"error":"invalid status {:?}; valid values: open, in-progress, done, closed"}}"#,
            req.status
        );
        return http_response(400, msg.into_bytes());
    }

    let mut all = load_tickets();
    let idx = match all.iter().position(|t| t.id == id) {
        Some(i) => i,
        None => return http_response(404, br#"{"error":"ticket not found"}"#.to_vec()),
    };
    all[idx].status = req.status;
    let updated = all[idx].clone();
    save_tickets(&all);

    let body = serde_json::to_vec(&updated).unwrap_or_default();
    http_response(200, body)
}

// ============================================================================
// Storage
// ============================================================================

fn load_tickets() -> Vec<Ticket> {
    match load_label_as_string(TICKETS_LIST_LABEL) {
        Ok(json) => serde_json::from_str(&json).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn save_tickets(tickets: &[Ticket]) {
    let json = serde_json::to_vec(tickets).unwrap_or_default();
    let _ = store_store_at_label(
        String::from(STORE_ID),
        String::from(TICKETS_LIST_LABEL),
        json,
    );
}

// ============================================================================
// Helpers
// ============================================================================

fn parse_query(query: &str) -> (Option<String>, Option<String>) {
    let mut status = None;
    let mut assignee = None;
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            let decoded = url_decode(v);
            match k {
                "status" => status = Some(decoded),
                "assignee" => assignee = Some(decoded),
                _ => {}
            }
        }
    }
    (status, assignee)
}

fn url_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'%' && i + 2 < bytes.len() {
            let hi = hex_digit(bytes[i + 1]);
            let lo = hex_digit(bytes[i + 2]);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as char);
                i += 3;
                continue;
            }
        }
        if b == b'+' {
            out.push(' ');
        } else {
            out.push(b as char);
        }
        i += 1;
    }
    out
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn http_response(status: u16, body: Vec<u8>) -> Vec<u8> {
    let reason = match status {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        status,
        reason,
        body.len()
    );
    let mut out = header.into_bytes();
    out.extend_from_slice(&body);
    out
}
