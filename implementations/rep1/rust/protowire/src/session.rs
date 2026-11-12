//! The batch protocol: a schema, a `--` separator line, then request lines.
//!
//! This is the logic behind the command-line tool, exposed so it can be
//! reused and tested without spawning a process.

use crate::error::{Error, Result};
use crate::hex;
use crate::schema::Schema;

/// Splits `input` into the schema source (everything before the first line
/// that is exactly `--`) and the request lines after it.
///
/// A final empty segment caused by a trailing newline is not a request.
pub fn split_input(input: &[u8]) -> (&[u8], Vec<&[u8]>) {
    // Locate the first line that is exactly `--`.
    let mut start = 0;
    loop {
        let end = input[start..].iter().position(|&b| b == b'\n').map_or(input.len(), |i| start + i);
        if &input[start..end] == b"--" {
            let mut body = &input[(end + 1).min(input.len())..];
            if let Some(stripped) = body.strip_suffix(b"\n") {
                body = stripped;
            } else if body.is_empty() {
                return (&input[..start], Vec::new());
            }
            return (&input[..start], body.split(|&b| b == b'\n').collect());
        }
        if end >= input.len() {
            return (input, Vec::new());
        }
        start = end + 1;
    }
}

/// Executes one request line against `schema`, returning its output line
/// (without the newline).
///
/// ```
/// let schema = protowire::Schema::parse("message A { int32 x = 1; }").unwrap();
/// assert_eq!(protowire::session::handle_request(&schema, b"decode A 082a").unwrap(), "{x: 42}");
/// assert_eq!(protowire::session::handle_request(&schema, b"encode A {x: 42}").unwrap(), "082a");
/// ```
pub fn handle_request(schema: &Schema, line: &[u8]) -> Result<String> {
    let (decoding, rest) = if let Some(r) = line.strip_prefix(b"decode ") {
        (true, r)
    } else if let Some(r) = line.strip_prefix(b"encode ") {
        (false, r)
    } else {
        return Err(Error::Request("unknown command"));
    };
    let name_end = rest.iter().position(|&b| b == b' ').unwrap_or(rest.len());
    let name = std::str::from_utf8(&rest[..name_end]).map_err(|_| Error::Request("bad message name"))?;
    let id = schema.message_id(name).ok_or_else(|| Error::UnknownMessage(name.to_owned()))?;
    let after = rest.get(name_end + 1..);
    if decoding {
        let bytes = match after {
            None => Vec::new(),
            Some([]) => return Err(Error::Request("trailing space")),
            Some(h) => hex::decode(h)?,
        };
        let msg = schema.decode(id, &bytes)?;
        Ok(schema.render(id, &msg))
    } else {
        let text = after.ok_or(Error::Request("missing message text"))?;
        let msg = schema.parse_text(id, text)?;
        Ok(hex::encode(&schema.encode(id, &msg)))
    }
}

/// Runs a whole input document and returns the complete output: one line
/// per request, `error` for any request that fails. Never fails itself,
/// except that an unparsable schema yields empty output.
pub fn run(input: &[u8]) -> Vec<u8> {
    let (schema_src, lines) = split_input(input);
    let mut out = Vec::new();
    let Ok(schema_text) = std::str::from_utf8(schema_src) else {
        return out;
    };
    let Ok(schema) = Schema::parse(schema_text) else {
        return out;
    };
    for line in lines {
        match handle_request(&schema, line) {
            Ok(s) => out.extend_from_slice(s.as_bytes()),
            Err(_) => out.extend_from_slice(b"error"),
        }
        out.push(b'\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitting() {
        let (s, l) = split_input(b"message A {}\n--\nx\ny\n");
        assert_eq!(s, b"message A {}\n");
        assert_eq!(l, vec![&b"x"[..], b"y"]);
        let (_, l) = split_input(b"m\n--\nx\ny");
        assert_eq!(l, vec![&b"x"[..], b"y"]);
        let (_, l) = split_input(b"m\n--\n");
        assert!(l.is_empty());
        let (_, l) = split_input(b"m\n--");
        assert!(l.is_empty());
        let (s, l) = split_input(b"m\n---\n--x\n--\na\n--\n");
        assert_eq!(s, b"m\n---\n--x\n");
        assert_eq!(l, vec![&b"a"[..], b"--"]);
    }

    #[test]
    fn request_edge_cases() {
        let s = Schema::parse("message A { int32 x = 1; }").unwrap();
        assert_eq!(handle_request(&s, b"decode A").unwrap(), "{}");
        assert!(handle_request(&s, b"decode A ").is_err());
        assert!(handle_request(&s, b"decode A 0").is_err());
        assert!(handle_request(&s, b"decode A 08 01").is_err());
        assert!(handle_request(&s, b"decode A 082A").is_err());
        assert!(handle_request(&s, b"encode A").is_err());
        assert!(handle_request(&s, b"encode A ").is_err());
        assert_eq!(handle_request(&s, b"encode A  {}").unwrap(), "");
        assert!(handle_request(&s, b"frobnicate A").is_err());
    }
}
