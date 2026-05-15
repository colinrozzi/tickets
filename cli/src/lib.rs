//! tickets-cli: a one-shot Theater actor that wraps the tickets HTTP API.
//!
//! The wrapper script (`cli/tickets`) builds a temporary manifest with
//! `initial_state` set to a JSON document describing the command, runs
//! `theater start`. We parse the command, talk HTTP to the tickets server,
//! write formatted output via the terminal handler, and shut down.

#![no_std]
extern crate alloc;

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use packr_guest::{export, import, pack_types, Value};
use serde::{Deserialize, Serialize};

packr_guest::setup_guest!();

pack_types! {
    imports {
        theater:simple/runtime {
            log: func(msg: string),
            shutdown: func(data: option<list<u8>>) -> result<_, string>,
        }
        theater:simple/tcp {
            connect: func(address: string) -> result<string, string>,
            send: func(connection-id: string, data: list<u8>) -> result<u64, string>,
            receive: func(connection-id: string, max-bytes: u32) -> result<list<u8>, string>,
            close: func(connection-id: string) -> result<_, string>,
        }
        theater:simple/terminal {
            write-stdout: func(data: list<u8>) -> result<u64, string>,
            write-stderr: func(data: list<u8>) -> result<u64, string>,
        }
    }
    exports {
        theater:simple/actor.init: func(state: value) -> result<tuple<bool, _>, string>,
    }
}

#[import(module = "theater:simple/runtime", name = "log")]
fn log(msg: String);

#[import(module = "theater:simple/runtime", name = "shutdown")]
fn shutdown(data: Option<Vec<u8>>) -> Result<(), String>;

#[import(module = "theater:simple/tcp", name = "connect")]
fn tcp_connect(address: String) -> Result<String, String>;

#[import(module = "theater:simple/tcp", name = "send")]
fn tcp_send(connection_id: String, data: Vec<u8>) -> Result<u64, String>;

#[import(module = "theater:simple/tcp", name = "receive")]
fn tcp_receive(connection_id: String, max_bytes: u32) -> Result<Vec<u8>, String>;

#[import(module = "theater:simple/tcp", name = "close")]
fn tcp_close(connection_id: String) -> Result<(), String>;

#[import(module = "theater:simple/terminal", name = "write-stdout")]
fn write_stdout(data: Vec<u8>) -> Result<u64, String>;

#[import(module = "theater:simple/terminal", name = "write-stderr")]
fn write_stderr(data: Vec<u8>) -> Result<u64, String>;

#[export(name = "theater:simple/actor.init")]
fn init(state: Value) -> Result<(bool, ()), String> {
    let raw = match state {
        Value::String(s) => s,
        _ => {
            err("tickets-cli: expected initial_state = JSON string with {cmd, ...}\n");
            shutdown_now();
            return Ok((false, ()));
        }
    };

    let req: CliCommand = match serde_json::from_str(&raw) {
        Ok(r) => r,
        Err(e) => {
            err(&format!("tickets-cli: parse error: {}\n", e));
            shutdown_now();
            return Ok((false, ()));
        }
    };

    if req.cmd.is_empty() {
        err("tickets-cli: missing 'cmd' field\n");
        shutdown_now();
        return Ok((false, ()));
    }
    if req.token.is_empty() {
        err("tickets-cli: missing 'token' field (set TICKETS_TOKEN)\n");
        shutdown_now();
        return Ok((false, ()));
    }

    let ok = run(&req).map(|_| true).unwrap_or_else(|e| {
        err(&format!("tickets-cli: {}\n", e));
        false
    });
    shutdown_now();
    Ok((ok, ()))
}

fn shutdown_now() {
    let _ = shutdown(None);
}

// ============================================================================
// CLI command shape — what the bash wrapper hands us in initial_state.
// ============================================================================

#[derive(Deserialize)]
struct CliCommand {
    #[serde(default)]
    cmd: String,
    #[serde(default = "default_api")]
    api: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    id: Option<u64>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    reporter: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    author: Option<String>,
}

fn default_api() -> String {
    String::from("127.0.0.1:8443")
}

// ============================================================================
// Response shapes
// ============================================================================

#[derive(Deserialize, Serialize)]
struct Ticket {
    id: u64,
    title: String,
    body: String,
    reporter: String,
    assignee: String,
    status: String,
    created_at: u64,
    #[serde(default)]
    comments: Vec<Comment>,
}

#[derive(Deserialize, Serialize, Clone)]
struct Comment {
    author: String,
    body: String,
    created_at: u64,
}

#[derive(Deserialize)]
struct TicketsList {
    #[serde(default)]
    tickets: Vec<Ticket>,
}

// ============================================================================
// Dispatch
// ============================================================================

fn run(req: &CliCommand) -> Result<(), String> {
    match req.cmd.as_str() {
        "list" => run_list(req),
        "new" => run_new(req),
        "show" => run_show(req),
        "status" => run_status(req),
        "comment" => run_comment(req),
        other => Err(format!("unknown cmd: {}", other)),
    }
}

fn run_list(req: &CliCommand) -> Result<(), String> {
    let mut query = String::new();
    if let Some(s) = &req.status {
        query.push_str(&format!("status={}", url_encode(s)));
    }
    if let Some(a) = &req.assignee {
        if !query.is_empty() {
            query.push('&');
        }
        query.push_str(&format!("assignee={}", url_encode(a)));
    }
    let path = if query.is_empty() {
        String::from("/v1/tickets")
    } else {
        format!("/v1/tickets?{}", query)
    };
    let body = http(req, "GET", &path, None)?;
    let resp: TicketsList = serde_json::from_str(&body)
        .map_err(|e| format!("parse /v1/tickets response: {}", e))?;
    if resp.tickets.is_empty() {
        out("(no tickets)\n");
    } else {
        for t in &resp.tickets {
            out(&format!(
                "#{}  [{}]  {}  (reporter={}, assignee={})\n",
                t.id, t.status, t.title, t.reporter, t.assignee
            ));
        }
    }
    Ok(())
}

fn run_new(req: &CliCommand) -> Result<(), String> {
    let title = req.title.as_ref().ok_or("new: --title required")?;
    let reporter = req.reporter.as_ref().ok_or("new: --reporter required")?;
    let assignee = req.assignee.as_ref().ok_or("new: --assignee required")?;
    let body = req.body.as_deref().unwrap_or("");

    #[derive(Serialize)]
    struct CreateBody<'a> {
        title: &'a str,
        body: &'a str,
        reporter: &'a str,
        assignee: &'a str,
    }
    let body_json = serde_json::to_string(&CreateBody {
        title,
        body,
        reporter,
        assignee,
    })
    .map_err(|e| format!("encode body: {}", e))?;

    let resp = http(req, "POST", "/v1/tickets", Some(&body_json))?;
    let t: Ticket = serde_json::from_str(&resp)
        .map_err(|e| format!("parse create response: {}", e))?;
    out(&format!(
        "created #{}  [{}]  {}  (reporter={}, assignee={})\n",
        t.id, t.status, t.title, t.reporter, t.assignee
    ));
    Ok(())
}

fn run_show(req: &CliCommand) -> Result<(), String> {
    let id = req.id.ok_or("show: --id required")?;
    let path = format!("/v1/tickets/{}", id);
    let body = http(req, "GET", &path, None)?;
    let t: Ticket = serde_json::from_str(&body)
        .map_err(|e| format!("parse show response: {}", e))?;
    out(&format!("#{}\n", t.id));
    out(&format!("status:   {}\n", t.status));
    out(&format!("title:    {}\n", t.title));
    out(&format!("reporter: {}\n", t.reporter));
    out(&format!("assignee: {}\n", t.assignee));
    out(&format!("created:  {}\n", epoch_ms_to_iso8601(t.created_at)));
    out("\n");
    out(&t.body);
    out("\n");
    if !t.comments.is_empty() {
        out("\n--- comments ---\n");
        for c in &t.comments {
            out(&format!(
                "{}  {}\n",
                epoch_ms_to_iso8601(c.created_at),
                c.author
            ));
            for line in c.body.split('\n') {
                out(&format!("  {}\n", line));
            }
            out("\n");
        }
    }
    Ok(())
}

fn run_comment(req: &CliCommand) -> Result<(), String> {
    let id = req.id.ok_or("comment: --id required")?;
    let author = req.author.as_ref().ok_or("comment: --author required")?;
    let body_text = req.body.as_ref().ok_or("comment: --body required")?;

    #[derive(Serialize)]
    struct CommentBody<'a> {
        author: &'a str,
        body: &'a str,
    }
    let body_json = serde_json::to_string(&CommentBody {
        author,
        body: body_text,
    })
    .map_err(|e| format!("encode body: {}", e))?;

    let path = format!("/v1/tickets/{}/comment", id);
    let resp = http(req, "POST", &path, Some(&body_json))?;
    let t: Ticket = serde_json::from_str(&resp)
        .map_err(|e| format!("parse comment response: {}", e))?;
    out(&format!(
        "commented on #{}  [{}]  {}  ({} comments)\n",
        t.id,
        t.status,
        t.title,
        t.comments.len()
    ));
    Ok(())
}

fn run_status(req: &CliCommand) -> Result<(), String> {
    let id = req.id.ok_or("status: --id required")?;
    let status = req.status.as_ref().ok_or("status: --status required")?;

    #[derive(Serialize)]
    struct StatusBody<'a> {
        status: &'a str,
    }
    let body_json = serde_json::to_string(&StatusBody { status })
        .map_err(|e| format!("encode body: {}", e))?;

    let path = format!("/v1/tickets/{}/status", id);
    let resp = http(req, "POST", &path, Some(&body_json))?;
    let t: Ticket = serde_json::from_str(&resp)
        .map_err(|e| format!("parse status response: {}", e))?;
    out(&format!(
        "updated #{}  [{}]  {}  (reporter={}, assignee={})\n",
        t.id, t.status, t.title, t.reporter, t.assignee
    ));
    Ok(())
}

// ============================================================================
// HTTP
// ============================================================================

fn http(req: &CliCommand, method: &str, path: &str, body: Option<&str>) -> Result<String, String> {
    let conn = tcp_connect(req.api.clone())
        .map_err(|e| format!("connect to {}: {}", req.api, e))?;
    let mut http_req = format!(
        "{} {} HTTP/1.1\r\nHost: {}\r\nAuthorization: Bearer {}\r\nConnection: close\r\n",
        method, path, req.api, req.token
    );
    if let Some(b) = body {
        http_req.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            b.len(),
            b
        ));
    } else {
        http_req.push_str("\r\n");
    }
    tcp_send(conn.clone(), http_req.into_bytes()).map_err(|e| format!("send: {}", e))?;

    let mut all = Vec::new();
    let mut body_start: Option<usize> = None;
    let mut content_length: Option<usize> = None;

    loop {
        if let (Some(hs), Some(cl)) = (body_start, content_length) {
            if all.len() >= hs + cl {
                break;
            }
        }

        let chunk = match tcp_receive(conn.clone(), 65536) {
            Ok(c) => c,
            Err(e) => {
                if let (Some(hs), Some(cl)) = (body_start, content_length) {
                    if all.len() >= hs + cl {
                        break;
                    }
                }
                return Err(format!("recv: {}", e));
            }
        };
        if chunk.is_empty() {
            break;
        }
        all.extend_from_slice(&chunk);

        if body_start.is_none() {
            if let Some(idx) = find_subseq(&all, b"\r\n\r\n") {
                body_start = Some(idx + 4);
                let header_str = core::str::from_utf8(&all[..idx]).unwrap_or("");
                for line in header_str.split("\r\n") {
                    if let Some((name, value)) = line.split_once(':') {
                        if name.trim().eq_ignore_ascii_case("content-length") {
                            if let Ok(n) = value.trim().parse::<usize>() {
                                content_length = Some(n);
                            }
                        }
                    }
                }
                if content_length.is_none() {
                    content_length = Some(usize::MAX);
                }
            }
        }
    }

    let _ = tcp_close(conn);

    let text = String::from_utf8(all).map_err(|_| String::from("non-utf8 response"))?;
    let start = body_start.unwrap_or_else(|| text.find("\r\n\r\n").map(|i| i + 4).unwrap_or(0));
    let end = match content_length {
        Some(n) if n != usize::MAX => start + n.min(text.len() - start),
        _ => text.len(),
    };
    let resp_body = text[start..end].to_string();

    // Surface non-2xx as Err so callers don't try to JSON-decode error bodies as
    // success types. Preserve the server's error body verbatim — it's already
    // shaped like {"error":"..."}.
    let status_line = text.lines().next().unwrap_or("");
    let mut parts = status_line.split_whitespace();
    let _http_version = parts.next();
    let status_code: u16 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    if !(200..300).contains(&status_code) {
        let detail = extract_error_message(&resp_body).unwrap_or(resp_body);
        return Err(format!("HTTP {}: {}", status_code, detail));
    }

    Ok(resp_body)
}

/// Pull the "error" field out of `{"error":"..."}` without depending on serde for
/// such a thin shape. Returns None if the body doesn't match.
fn extract_error_message(body: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct ErrBody {
        error: String,
    }
    serde_json::from_str::<ErrBody>(body).ok().map(|e| e.error)
}

fn find_subseq(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ============================================================================
// Output helpers
// ============================================================================

fn out(s: &str) {
    let _ = write_stdout(s.as_bytes().to_vec());
}

fn err(s: &str) {
    let _ = write_stderr(s.as_bytes().to_vec());
}

/// Render epoch milliseconds (UTC) as ISO-8601 "YYYY-MM-DDTHH:MM:SSZ".
/// Uses Hinnant's civil-from-days algorithm; valid for u64 ms (≈ year 1970 onward).
fn epoch_ms_to_iso8601(ms: u64) -> String {
    let secs = ms / 1000;
    let days = secs / 86400;
    let tod = secs % 86400;
    let hour = tod / 3600;
    let minute = (tod % 3600) / 60;
    let second = tod % 60;

    let z: u64 = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = (yoe as i64) + (era as i64) * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    if month <= 2 {
        year += 1;
    }

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, minute, second
    )
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        let ok = byte.is_ascii_alphanumeric()
            || byte == b'-'
            || byte == b'.'
            || byte == b'_'
            || byte == b'~';
        if ok {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{:02X}", byte));
        }
    }
    out
}
