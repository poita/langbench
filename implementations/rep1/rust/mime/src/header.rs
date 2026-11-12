//! Header block parsing and unfolding.

use crate::charset::decode_utf8;
use crate::lines::Lines;
use crate::scan::strip_blanks;

/// One header field: the name and the unfolded raw value, both decoded as UTF-8.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    /// The text before the first `:`.
    pub name: String,
    /// The text after the first `:`, with folding line breaks removed.
    pub raw_value: String,
}

impl Field {
    /// The lower-cased name with surrounding blanks stripped.
    pub fn key(&self) -> String {
        strip_blanks(&self.name).to_ascii_lowercase()
    }

    /// The value as shown in the output dump.
    pub fn display_value(&self) -> String {
        match self.key().as_str() {
            "content-disposition" | "content-id" | "content-transfer-encoding"
            | "content-type" | "date" | "in-reply-to" | "message-id" | "mime-version"
            | "received" | "references" | "return-path" => collapse(&self.raw_value),
            _ => crate::rfc2047::decode_unstructured(&self.raw_value),
        }
    }
}

/// Replaces each run of SPACE and TAB with one SPACE and strips both ends.
pub fn collapse(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_run = false;
    for c in s.chars() {
        if c == ' ' || c == '\t' {
            in_run = true;
        } else {
            if in_run {
                out.push(' ');
                in_run = false;
            }
            out.push(c);
        }
    }
    if in_run {
        out.push(' ');
    }
    strip_blanks(&out).trim_matches(' ').to_string()
}

fn is_name_byte(b: u8) -> bool {
    (0x21..=0x39).contains(&b) || (0x3B..=0x7E).contains(&b)
}

/// Splits `data` (lines terminated by LF) into header fields and a body.
///
/// Returns the fields and the offset where the body starts.
pub fn parse_headers(data: &[u8]) -> (Vec<Field>, usize) {
    let mut fields = Vec::new();
    let mut current: Option<Vec<u8>> = None;
    let mut body_start = data.len();

    fn flush(current: &mut Option<Vec<u8>>, fields: &mut Vec<Field>) {
        if let Some(bytes) = current.take() {
            let colon = bytes.iter().position(|&b| b == b':').unwrap_or(bytes.len());
            fields.push(Field {
                name: decode_utf8(&bytes[..colon]),
                raw_value: decode_utf8(bytes.get(colon + 1..).unwrap_or(&[])),
            });
        }
    }

    for (n, line) in Lines::lf(data).enumerate() {
        let text = &data[line.start..line.end];
        if text.is_empty() {
            body_start = line.next;
            break;
        }
        if n > 0 && (text[0] == b' ' || text[0] == b'\t') {
            if let Some(cur) = current.as_mut() {
                cur.extend_from_slice(text);
                continue;
            }
        }
        match text.iter().position(|&b| b == b':') {
            Some(colon) if colon > 0 && text[..colon].iter().all(|&b| is_name_byte(b)) => {
                flush(&mut current, &mut fields);
                current = Some(text.to_vec());
            }
            _ => {
                body_start = line.start;
                break;
            }
        }
    }
    flush(&mut current, &mut fields);
    (fields, body_start)
}

/// Finds the first field named `name` (lower case), ignoring case and blanks.
pub fn find_field<'a>(fields: &'a [Field], name: &str) -> Option<&'a Field> {
    fields.iter().find(|f| f.key() == name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_header_and_body() {
        let data = b"Subject: a\n b\nX:y\n\nbody\n";
        let (fields, start) = parse_headers(data);
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[0].name, "Subject");
        assert_eq!(fields[0].raw_value, " a b");
        assert_eq!(&data[start..], b"body\n");
    }

    #[test]
    fn non_field_line_ends_block() {
        let data = b"A: 1\nSubject :x\nB: 2\n";
        let (fields, start) = parse_headers(data);
        assert_eq!(fields.len(), 1);
        assert_eq!(&data[start..], b"Subject :x\nB: 2\n");
        for bad in [&b"no colon here\n"[..], b": novalue\n", b"From nobody Mon Sep  1\n", b" lead: x\n"] {
            let (f, s) = parse_headers(bad);
            assert!(f.is_empty());
            assert_eq!(s, 0);
        }
    }

    #[test]
    fn headers_only() {
        let (fields, start) = parse_headers(b"A: 1\nB: 2");
        assert_eq!(fields.len(), 2);
        assert_eq!(start, 9);
    }

    #[test]
    fn collapse_runs() {
        assert_eq!(collapse("  a \t b  "), "a b");
        assert_eq!(collapse(""), "");
    }

    #[test]
    fn display_value_rules() {
        let f = Field { name: "Content-Type ".into(), raw_value: "  text/plain;   x=\"=?utf-8?Q?a?=\" ".into() };
        assert_eq!(f.key(), "content-type");
        assert_eq!(f.display_value(), "text/plain; x=\"=?utf-8?Q?a?=\"");
    }
}
