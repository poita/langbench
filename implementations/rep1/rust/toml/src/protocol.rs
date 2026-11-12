//! The stdin/stdout protocol used by the command-line tool.
//!
//! Input is a mode line (`decode` or `encode`) followed by the document.

use crate::{encoder, parse_bytes, tagged_json};

/// Runs one request and returns the bytes to write to stdout.
///
/// In `decode` mode an invalid TOML document yields `error\n`. In `encode`
/// mode malformed tagged JSON, or a missing/unknown mode line, is reported as
/// `Err` with a message.
pub fn process(input: &[u8]) -> Result<Vec<u8>, String> {
    let nl = input
        .iter()
        .position(|&b| b == b'\n')
        .ok_or("missing mode line")?;
    let (mode, doc) = (&input[..nl], &input[nl + 1..]);
    match mode {
        b"decode" => {
            let mut out = match parse_bytes(doc) {
                Ok(value) => tagged_json::to_string(&value),
                Err(_) => "error".to_string(),
            };
            out.push('\n');
            Ok(out.into_bytes())
        }
        b"encode" => {
            let text = std::str::from_utf8(doc).map_err(|e| e.to_string())?;
            let value = tagged_json::from_str(text).map_err(|e| e.to_string())?;
            encoder::to_toml(&value)
                .map(String::into_bytes)
                .map_err(|e| e.to_string())
        }
        _ => Err("unknown mode (expected `decode` or `encode`)".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_and_encode() {
        let out = process(b"decode\na = 1\n").unwrap();
        assert_eq!(out, b"{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}\n");
        let out = process(b"encode\n{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}").unwrap();
        assert_eq!(out, b"a = 1\n");
    }

    #[test]
    fn decode_error() {
        assert_eq!(process(b"decode\na = \n").unwrap(), b"error\n");
        assert_eq!(process(b"decode\n\xff").unwrap(), b"error\n");
    }

    #[test]
    fn bad_mode() {
        assert!(process(b"nope\n").is_err());
        assert!(process(b"decode").is_err());
    }
}
