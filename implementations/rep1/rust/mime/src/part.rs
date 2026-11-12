//! MIME part tree construction.

use crate::charset;
use crate::header::{find_field, parse_headers, Field};
use crate::lines::{normalize_newlines, Lines};
use crate::params::Structured;
use crate::transfer::decode_body;

/// What kind of node a part is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// A `multipart/*` part with a usable boundary.
    Multipart {
        /// The boundary parameter.
        boundary: String,
        /// Byte length of the preamble.
        preamble: usize,
        /// Byte length of the epilogue, if a close delimiter was found.
        epilogue: Option<usize>,
    },
    /// A `message/rfc822` part holding exactly one child message.
    Message,
    /// Anything else.
    Leaf,
}

/// One node of the MIME tree. Parts are stored in pre-order.
#[derive(Debug, Clone)]
pub struct Part {
    /// Pre-order index; the whole message is part 0.
    pub index: usize,
    /// Nesting depth; the whole message is at depth 0.
    pub depth: usize,
    /// The part's header fields.
    pub headers: Vec<Field>,
    /// Effective top-level media type (lower case).
    pub main_type: String,
    /// Effective media subtype (lower case).
    pub sub_type: String,
    /// The normalised charset name, for `text/*` parts.
    pub charset: Option<String>,
    /// The Content-Transfer-Encoding token (`7bit` when absent).
    pub encoding: String,
    /// The disposition type when a `Content-Disposition` header is present.
    pub disposition: Option<String>,
    /// The filename from `Content-Disposition` or, failing that, `Content-Type`.
    pub filename: Option<String>,
    /// Node kind.
    pub kind: Kind,
    /// Number of direct children (containers only).
    pub children: usize,
    /// Decoded content (leaves only).
    pub content: Vec<u8>,
    /// Decoded text (`text/*` leaves only).
    pub text: Option<String>,
}

impl Part {
    /// `type/subtype`.
    pub fn media_type(&self) -> String {
        format!("{}/{}", self.main_type, self.sub_type)
    }

    /// Whether this part is a leaf.
    pub fn is_leaf(&self) -> bool {
        self.kind == Kind::Leaf
    }
}

/// Parses a whole message (CRLF line endings are normalised first) and
/// returns its parts in pre-order; the first one is the message itself.
pub fn parse_parts(message: &[u8]) -> Vec<Part> {
    let data = normalize_newlines(message);
    let mut parts = Vec::new();
    parse_part(&data, 0, false, &mut parts);
    parts
}

fn is_token(s: &str) -> bool {
    !s.is_empty()
        && !s.chars().any(|c| " \t()<>@,;:\\\"/[]?=".contains(c))
}

fn effective_type(ct: Option<&Structured>, parent_is_digest: bool) -> (String, String) {
    if let Some(ct) = ct {
        let v = ct.value_lower();
        if let Some((t, s)) = v.split_once('/') {
            if is_token(t) && is_token(s) {
                return (t.to_string(), s.to_string());
            }
        }
    }
    if parent_is_digest {
        ("message".into(), "rfc822".into())
    } else {
        ("text".into(), "plain".into())
    }
}

fn parse_part(data: &[u8], depth: usize, parent_is_digest: bool, out: &mut Vec<Part>) {
    let index = out.len();
    let (headers, body_start) = parse_headers(data);
    let body = &data[body_start..];

    let ct = find_field(&headers, "content-type").map(|f| Structured::parse(&f.raw_value));
    let cd = find_field(&headers, "content-disposition").map(|f| Structured::parse(&f.raw_value));
    let cte = find_field(&headers, "content-transfer-encoding")
        .map(|f| Structured::parse(&f.raw_value).value_lower());

    let (main_type, sub_type) = effective_type(ct.as_ref(), parent_is_digest);
    let encoding = cte.unwrap_or_else(|| "7bit".to_string());
    let disposition = cd.as_ref().map(|cd| {
        let v = cd.value_lower();
        if v.is_empty() {
            "inline".to_string()
        } else {
            v
        }
    });
    let filename = cd
        .as_ref()
        .and_then(|cd| cd.param("filename"))
        .or_else(|| ct.as_ref().and_then(|ct| ct.param("name")))
        .map(str::to_string);
    let charset_name = if main_type == "text" {
        Some(match ct.as_ref().and_then(|ct| ct.param("charset")) {
            Some(cs) => charset::normalize_name(cs),
            None => "us-ascii".to_string(),
        })
    } else {
        None
    };
    let boundary = ct
        .as_ref()
        .and_then(|ct| ct.param("boundary"))
        .filter(|b| !b.is_empty() && main_type == "multipart")
        .map(str::to_string);

    out.push(Part {
        index,
        depth,
        headers,
        main_type: main_type.clone(),
        sub_type: sub_type.clone(),
        charset: charset_name.clone(),
        encoding: encoding.clone(),
        disposition,
        filename,
        kind: Kind::Leaf,
        children: 0,
        content: Vec::new(),
        text: None,
    });

    if let Some(boundary) = boundary {
        let (ranges, preamble, epilogue) = split_multipart(body, boundary.as_bytes());
        let digest = sub_type == "digest";
        for (s, e) in &ranges {
            parse_part(&body[*s..*e], depth + 1, digest, out);
        }
        let part = &mut out[index];
        part.children = ranges.len();
        part.kind = Kind::Multipart { boundary, preamble, epilogue };
    } else if main_type == "message" && sub_type == "rfc822" {
        let inner = decode_body(body, &encoding);
        parse_part(&inner, depth + 1, false, out);
        let part = &mut out[index];
        part.children = 1;
        part.kind = Kind::Message;
    } else {
        let content = decode_body(body, &encoding);
        let part = &mut out[index];
        if let Some(cs) = &charset_name {
            part.text = Some(charset::decode(&content, cs));
        }
        part.content = content;
    }
}

/// If `line` is a delimiter line for boundary `bb`, returns whether it is a
/// close delimiter.
fn delimiter(line: &[u8], bb: &[u8]) -> Option<bool> {
    let rest = line.strip_prefix(b"--")?.strip_prefix(bb)?;
    let (close, tail) = match rest.strip_prefix(b"--") {
        Some(t) => (true, t),
        None => (false, rest),
    };
    tail.iter().all(|&b| b == b' ' || b == b'\t').then_some(close)
}

fn trim_one_lf(b: &[u8]) -> &[u8] {
    b.strip_suffix(b"\n").unwrap_or(b)
}

/// Splits a multipart body. Returns the child ranges (offsets into `body`),
/// the preamble length and the epilogue length.
fn split_multipart(body: &[u8], bb: &[u8]) -> (Vec<(usize, usize)>, usize, Option<usize>) {
    let mut delims: Vec<(usize, usize, bool)> = Vec::new(); // (line start, next, close)
    for line in Lines::lf(body) {
        if let Some(close) = delimiter(&body[line.start..line.end], bb) {
            delims.push((line.start, line.next, close));
            if close {
                break;
            }
        }
    }
    let Some(&(first_start, first_next, first_close)) = delims.first() else {
        return (Vec::new(), body.len(), None);
    };
    let preamble = trim_one_lf(&body[..first_start]).len();
    if first_close {
        return (Vec::new(), preamble, Some(body.len() - first_next));
    }

    let mut ranges = Vec::new();
    let mut epilogue = None;
    let mut start = first_next;
    for &(d_start, d_next, close) in &delims[1..] {
        let end = start + trim_one_lf(&body[start..d_start]).len();
        ranges.push((start, end));
        start = d_next;
        if close {
            epilogue = Some(body.len() - d_next);
        }
    }
    if epilogue.is_none() {
        let end = start + trim_one_lf(&body[start..]).len();
        ranges.push((start, end));
    }
    (ranges, preamble, epilogue)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delimiter_lines() {
        assert_eq!(delimiter(b"--X", b"X"), Some(false));
        assert_eq!(delimiter(b"--X--", b"X"), Some(true));
        assert_eq!(delimiter(b"--X \t", b"X"), Some(false));
        assert_eq!(delimiter(b"--X-- ", b"X"), Some(true));
        assert_eq!(delimiter(b"--XY", b"X"), None);
        assert_eq!(delimiter(b"--X-", b"X"), None);
        assert_eq!(delimiter(b" --X", b"X"), None);
    }

    #[test]
    fn multipart_ranges() {
        let body = b"pre\n--X\none\n--X\n\n--X--\nepi\n";
        let (ranges, pre, epi) = split_multipart(body, b"X");
        assert_eq!(pre, 3);
        assert_eq!(epi, Some(4));
        let kids: Vec<&[u8]> = ranges.iter().map(|&(s, e)| &body[s..e]).collect();
        assert_eq!(kids, vec![&b"one"[..], b""]);
        let (ranges, pre, epi) = split_multipart(b"--X\na\nb\n", b"X");
        assert_eq!((pre, epi), (0, None));
        assert_eq!(&b"--X\na\nb\n"[ranges[0].0..ranges[0].1], b"a\nb");
        let (ranges, pre, epi) = split_multipart(b"no delimiters\n", b"X");
        assert_eq!((ranges.len(), pre, epi), (0, 14, None));
    }

    #[test]
    fn tree_numbering() {
        let msg = b"Content-Type: multipart/mixed; boundary=B\n\n--B\nContent-Type: message/rfc822\n\nSubject: hi\n\nbody\n--B\n\nplain\n--B--\n";
        let parts = parse_parts(msg);
        let shape: Vec<(usize, usize, String)> =
            parts.iter().map(|p| (p.index, p.depth, p.media_type())).collect();
        assert_eq!(
            shape,
            vec![
                (0, 0, "multipart/mixed".to_string()),
                (1, 1, "message/rfc822".to_string()),
                (2, 2, "text/plain".to_string()),
                (3, 1, "text/plain".to_string()),
            ]
        );
        assert_eq!(parts[2].content, b"body");
        assert_eq!(parts[3].content, b"plain");
    }

    #[test]
    fn digest_default_type() {
        let msg = b"Content-Type: multipart/digest; boundary=B\n\n--B\n\nSubject: x\n\nhi\n--B--\n";
        let parts = parse_parts(msg);
        assert_eq!(parts[1].media_type(), "message/rfc822");
        assert_eq!(parts[2].media_type(), "text/plain");
    }
}
