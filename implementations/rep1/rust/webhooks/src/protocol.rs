//! The line-oriented command protocol.
//!
//! [`run_commands`] interprets a whole stdin transcript and returns the whole
//! stdout transcript. Malformed lines never fail: they produce the single word
//! `error`.
//!
//! Commands (fields are separated by single spaces; byte strings are lowercase
//! hex, with `-` for the empty string):
//!
//! ```text
//! sha256 <hex>
//! hmac <key-hex> <msg-hex>
//! b64enc <hex>            b64urlenc <hex>          b64dec <text-hex>
//! secret <secret>
//! sign <secrets> <id> <ts> <payload-hex>
//! verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>
//! simulate  (endpoint ... / event ... / end)
//! ```
//!
//! ```
//! let out = webhooks::run_commands(b"sha256 616263\nb64enc 666f6f\nbogus\n");
//! assert_eq!(
//!     out,
//!     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\nZm9v\nerror\n"
//! );
//! ```

use crate::simulator::{simulate, Endpoint, Event, Filter, Response};
use crate::{base64, hex, hmac_sha256, sha256, sign_header, verify, Secret, VerifyOutcome};
use crate::signature::is_canonical_int;
use std::collections::HashSet;

/// Maximum number of secrets in one `<secrets>` field.
const MAX_SECRETS: usize = 16;
/// Limits of a `simulate` block.
const MAX_ENDPOINTS: usize = 64;
const MAX_EVENTS: usize = 20_000;

/// Runs every command in `input` and returns the output, one result per line
/// (each terminated by `\n`).
pub fn run_commands(input: &[u8]) -> String {
    let mut out = String::new();
    let mut lines = input.split(|&c| c == b'\n').filter(|l| !is_blank(l));
    while let Some(line) = lines.next() {
        let result = if line == b"simulate" {
            run_block(&mut lines)
        } else {
            run_command(line)
        };
        match result {
            Some(text) => out.push_str(&text),
            None => out.push_str("error"),
        }
        out.push('\n');
    }
    out
}

fn is_blank(line: &[u8]) -> bool {
    line.iter().all(|&c| c == b' ')
}

/// Splits a line into fields; `None` if any field is empty.
fn fields(line: &[u8]) -> Option<Vec<&[u8]>> {
    let f: Vec<&[u8]> = line.split(|&c| c == b' ').collect();
    if f.iter().any(|x| x.is_empty()) {
        None
    } else {
        Some(f)
    }
}

fn printable(field: &[u8], max: usize) -> bool {
    !field.is_empty() && field.len() <= max && field.iter().all(|&c| (0x21..=0x7e).contains(&c))
}

/// `<id>`: 1..256 printable ASCII characters.
fn is_id(field: &[u8]) -> bool {
    printable(field, 256)
}

/// `[A-Za-z0-9_.-]{1,64}`
fn is_ident(field: &[u8]) -> bool {
    !field.is_empty()
        && field.len() <= 64
        && field.iter().all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-'))
}

fn ascii(field: &[u8]) -> Option<&str> {
    std::str::from_utf8(field).ok()
}

fn parse_secrets(field: &[u8]) -> Option<Vec<Secret>> {
    let mut out = Vec::new();
    for entry in field.split(|&c| c == b',') {
        if out.len() == MAX_SECRETS || !printable(entry, 512) {
            return None;
        }
        out.push(Secret::parse_bytes(entry).ok()?);
    }
    Some(out)
}

fn parse_filter(field: &[u8]) -> Option<Filter> {
    if field == b"*" {
        return Some(Filter::All);
    }
    let types: Vec<&[u8]> = field.split(|&c| c == b',').collect();
    if types.len() > 16 || !types.iter().all(|t| is_ident(t)) {
        return None;
    }
    Some(Filter::Types(types.iter().map(|t| ascii(t).unwrap().to_string()).collect()))
}

fn parse_script(field: &[u8]) -> Option<Vec<Response>> {
    let entries: Vec<&[u8]> = field.split(|&c| c == b',').collect();
    if entries.len() > 64 {
        return None;
    }
    entries
        .iter()
        .map(|e| match *e {
            b"timeout" => Some(Response::Timeout),
            [a @ b'1'..=b'5', b @ b'0'..=b'9', c @ b'0'..=b'9'] => {
                Some(Response::Status((a - b'0') as u16 * 100 + (b - b'0') as u16 * 10 + (c - b'0') as u16))
            }
            _ => None,
        })
        .collect()
}

/// Executes one non-`simulate` command line. `None` means `error`.
fn run_command(line: &[u8]) -> Option<String> {
    let f = fields(line)?;
    match (f[0], f.len()) {
        (b"sha256", 2) => Some(hex::encode(&sha256(&hex::decode_arg(f[1])?))),
        (b"hmac", 3) => {
            let key = hex::decode_arg(f[1])?;
            let msg = hex::decode_arg(f[2])?;
            Some(hex::encode(&hmac_sha256(&key, &msg)))
        }
        (b"b64enc", 2) => Some(dash(base64::encode(&hex::decode_arg(f[1])?))),
        (b"b64urlenc", 2) => Some(dash(base64::encode_url(&hex::decode_arg(f[1])?))),
        (b"b64dec", 2) => {
            let text = hex::decode_arg(f[1])?;
            Some(hex::encode_or_dash(&base64::decode(&text)?))
        }
        (b"secret", 2) => {
            if !printable(f[1], 512) {
                return None;
            }
            Some(hex::encode(Secret::parse_bytes(f[1]).ok()?.key_bytes()))
        }
        (b"sign", 5) => {
            let secrets = parse_secrets(f[1])?;
            if !is_id(f[2]) {
                return None;
            }
            is_canonical_int(f[3])?;
            let payload = hex::decode_arg(f[4])?;
            Some(sign_header(&secrets, ascii(f[2])?, ascii(f[3])?, &payload))
        }
        (b"verify", 7) => {
            let secrets = parse_secrets(f[1])?;
            if !is_id(f[2]) || !printable(f[3], 64) {
                return None;
            }
            let now = is_canonical_int(f[4])?;
            let header = hex::decode_arg(f[5])?;
            let payload = hex::decode_arg(f[6])?;
            Some(match verify(&secrets, ascii(f[2])?, ascii(f[3])?, now, &header, &payload) {
                VerifyOutcome::Ok { secret, token } => format!("ok {secret} {token}"),
                VerifyOutcome::Fail(why) => format!("fail {why}"),
            })
        }
        _ => None,
    }
}

fn dash(s: String) -> String {
    if s.is_empty() {
        "-".to_string()
    } else {
        s
    }
}

enum Phase {
    Endpoints,
    Events,
}

/// Accumulates the lines of a `simulate` block.
struct Block {
    endpoints: Vec<Endpoint>,
    events: Vec<Event>,
    endpoint_ids: HashSet<Vec<u8>>,
    event_ids: HashSet<Vec<u8>>,
    phase: Phase,
}

impl Block {
    fn new() -> Self {
        Block {
            endpoints: Vec::new(),
            events: Vec::new(),
            endpoint_ids: HashSet::new(),
            event_ids: HashSet::new(),
            phase: Phase::Endpoints,
        }
    }

    /// Adds one block line; `None` means the block is malformed.
    fn add_line(&mut self, line: &[u8]) -> Option<()> {
        let f = fields(line)?;
        match (f[0], f.len()) {
            (b"endpoint", 5) => {
                if !matches!(self.phase, Phase::Endpoints)
                    || self.endpoints.len() >= MAX_ENDPOINTS
                    || !is_ident(f[1])
                    || self.endpoint_ids.contains(f[1])
                {
                    return None;
                }
                let endpoint = Endpoint {
                    id: ascii(f[1])?.to_string(),
                    secrets: parse_secrets(f[2])?,
                    filter: parse_filter(f[3])?,
                    script: parse_script(f[4])?,
                };
                self.endpoint_ids.insert(f[1].to_vec());
                self.endpoints.push(endpoint);
            }
            (b"event", 5) => {
                self.phase = Phase::Events;
                if self.events.len() >= MAX_EVENTS || !is_ident(f[1]) || self.event_ids.contains(f[1]) {
                    return None;
                }
                if !is_ident(f[3]) {
                    return None;
                }
                let event = Event {
                    id: ascii(f[1])?.to_string(),
                    ts: is_canonical_int(f[2])?,
                    kind: ascii(f[3])?.to_string(),
                    payload: hex::decode_arg(f[4])?,
                };
                self.event_ids.insert(f[1].to_vec());
                self.events.push(event);
            }
            _ => return None,
        }
        Some(())
    }
}

/// Reads the rest of a `simulate` block (blank lines already filtered out) and
/// runs it. `None` means the block is malformed.
fn run_block<'a>(lines: &mut impl Iterator<Item = &'a [u8]>) -> Option<String> {
    let mut block = Block::new();
    let mut valid = true;
    loop {
        // End of input before `end` makes the block an error.
        let line = lines.next()?;
        if line == b"end" {
            break;
        }
        // After a violation we only look for the terminating `end`.
        if valid && block.add_line(line).is_none() {
            valid = false;
        }
    }
    if !valid || block.endpoints.is_empty() {
        return None;
    }
    Some(simulate(&block.endpoints, &block.events).render())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(s: &str) -> Vec<String> {
        run_commands(s.as_bytes()).lines().map(String::from).collect()
    }

    #[test]
    fn blank_lines_and_missing_final_newline() {
        assert_eq!(run("\n   \nsha256 -"), vec!["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]);
    }

    #[test]
    fn field_errors() {
        for bad in [
            "sha256", "sha256  -", " sha256 -", "sha256 - ", "sha256 ABCD", "sha256 abc", "sha256 -- ",
            "frobnicate 1", "sha256\t-", "simulate now", "end", "endpoint a b c d", "event a 1 t -",
        ] {
            assert_eq!(run(bad), vec!["error"], "{bad:?}");
        }
    }

    #[test]
    fn b64dec_and_secret() {
        assert_eq!(run("b64dec 5a6d3976\nb64dec -\nb64dec 3d"), vec!["666f6f", "-", "error"]);
        assert_eq!(
            run("secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw\nsecret whsec_\nsecret a,b\nsecret ~~"),
            vec!["31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0", "error", "error", "error"]
        );
    }

    #[test]
    fn sign_requires_canonical_ts_but_verify_does_not() {
        assert_eq!(run("sign c2VjcmV0 id 01 -"), vec!["error"]);
        assert_eq!(run("verify c2VjcmV0 id 01 5 78 -"), vec!["fail invalid-timestamp"]);
        assert_eq!(run("verify c2VjcmV0 id 1 5x 78 -"), vec!["error"]);
    }

    #[test]
    fn secrets_limits() {
        let ok = vec!["c2VjcmV0"; 16].join(",");
        let bad = vec!["c2VjcmV0"; 17].join(",");
        assert_eq!(run(&format!("sign {ok} id 1 -"))[0].split(' ').count(), 16);
        assert_eq!(run(&format!("sign {bad} id 1 -")), vec!["error"]);
        assert_eq!(run("sign c2VjcmV0, id 1 -"), vec!["error"]);
    }

    const SIM: &str = "simulate\n\
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200\n\
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200\n\
event msg_1 1700000000 user.created 7b7d\n\
event msg_2 1700000100 repo.pushed 7b7d\n\
end\n";

    #[test]
    fn simulate_worked_example() {
        let out = run(SIM);
        assert_eq!(out[0], "sim 5 3");
        assert_eq!(out[1], "attempt 1 msg_1 ep_a 1 1700000000 failure 500");
        assert_eq!(out[3], "attempt 3 msg_1 ep_a 2 1700000005 timeout -");
        assert_eq!(
            out[8],
            "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U="
        );
    }

    #[test]
    fn malformed_block_swallows_until_end() {
        let input = "simulate\nendpoint a c2VjcmV0 * 200\nevent e 1 t -\nendpoint b c2VjcmV0 * 200\nsimulate\nend\nsha256 -\n";
        assert_eq!(
            run(input),
            vec!["error", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
        );
    }

    #[test]
    fn block_errors() {
        // No endpoints, duplicate ids, EOF before end.
        assert_eq!(run("simulate\nend"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 200\nendpoint a c2VjcmV0 * 200\nend"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 200\n"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 99\nend"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 600\nend"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 *,x 200\nend"), vec!["error"]);
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 200\nend "), vec!["error"]);
    }

    #[test]
    fn empty_event_list_is_fine() {
        assert_eq!(run("simulate\nendpoint a c2VjcmV0 * 200\nend"), vec!["sim 0 0"]);
    }

    #[test]
    fn block_limits() {
        let mut s = String::from("simulate\n");
        for i in 0..65 {
            s.push_str(&format!("endpoint e{i} c2VjcmV0 * 200\n"));
        }
        s.push_str("end\n");
        assert_eq!(run(&s), vec!["error"]);
    }
}
