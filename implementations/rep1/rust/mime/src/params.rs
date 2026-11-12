//! Structured header values (`Content-Type` and friends) and RFC 2231
//! parameter assembly.

use std::collections::HashMap;

use crate::charset;
use crate::rfc2047::decode_unstructured;
use crate::scan::{quoted_string, strip_blanks};

/// A parsed `value; name=param; ...` header.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Structured {
    /// The first segment, exactly as written (not stripped or lower-cased).
    pub value: String,
    params: HashMap<String, String>,
}

impl Structured {
    /// Parses an unfolded raw header value.
    pub fn parse(raw: &str) -> Structured {
        let chars: Vec<char> = raw.chars().collect();
        let mut segments = split_segments(&chars);
        let value = segments.remove(0);

        // Raw parameters in order of first appearance.
        let mut raw_params: Vec<(String, String)> = Vec::new();
        for seg in &segments {
            let Some(eq) = seg.find('=') else { continue };
            let name = strip_blanks(&seg[..eq]).to_lowercase();
            if raw_params.iter().any(|(n, _)| *n == name) {
                continue;
            }
            let rest = strip_blanks(&seg[eq + 1..]);
            let value = if rest.starts_with('"') {
                let rc: Vec<char> = rest.chars().collect();
                quoted_string(&rc, 0).0
            } else {
                rest.to_string()
            };
            raw_params.push((name, value));
        }
        Structured { value, params: assemble(raw_params) }
    }

    /// The first segment stripped of blanks and lower-cased.
    pub fn value_lower(&self) -> String {
        strip_blanks(&self.value).to_lowercase()
    }

    /// The effective value of parameter `name` (lower case), if any.
    pub fn param(&self, name: &str) -> Option<&str> {
        self.params.get(name).map(String::as_str)
    }
}

/// Splits at every `;` that is not inside a quoted string.
fn split_segments(chars: &[char]) -> Vec<String> {
    let mut segments = Vec::new();
    let mut cur = String::new();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            ';' => {
                segments.push(std::mem::take(&mut cur));
                i += 1;
            }
            '"' => {
                let (_, next) = quoted_string(chars, i);
                cur.extend(&chars[i..next]);
                i = next;
            }
            c => {
                cur.push(c);
                i += 1;
            }
        }
    }
    segments.push(cur);
    segments
}

/// Decimal segment number, comparable without overflow.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct SegNo(usize, String);

impl SegNo {
    fn new(digits: &str) -> SegNo {
        let t = digits.trim_start_matches('0');
        SegNo(t.len(), t.to_string())
    }

    fn is_zero(&self) -> bool {
        self.0 == 0
    }
}

struct Segment {
    no: SegNo,
    extended: bool,
    value: String,
}

/// Interprets a raw parameter name: `Some((base, Some(n), ext))` for segments,
/// `Some((base, None, true))` for `base*`, `None` for plain names.
fn classify(name: &str) -> Option<(&str, Option<&str>, bool)> {
    let (stem, extended) = match name.strip_suffix('*') {
        Some(s) => (s, true),
        None => (name, false),
    };
    if let Some(star) = stem.rfind('*') {
        let digits = &stem[star + 1..];
        if star > 0 && !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
            return Some((&stem[..star], Some(digits), extended));
        }
    }
    if extended && !stem.is_empty() {
        return Some((stem, None, true));
    }
    None
}

fn percent_decode(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            if let Some(v) = crate::transfer::hex_pair(&b[i + 1..]) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// Splits `charset'language'text`; the charset defaults to us-ascii.
fn split_extended(value: &str) -> (String, &str) {
    if let Some(a) = value.find('\'') {
        if let Some(b) = value[a + 1..].find('\'') {
            let cs = &value[..a];
            let cs = if cs.is_empty() { "us-ascii" } else { cs };
            return (cs.to_string(), &value[a + 1 + b + 1..]);
        }
    }
    ("us-ascii".to_string(), value)
}

fn decode_extended(value: &str) -> String {
    let (cs, text) = split_extended(value);
    charset::decode(&percent_decode(text), &cs)
}

fn assemble(raw: Vec<(String, String)>) -> HashMap<String, String> {
    let mut plain: Vec<(String, String)> = Vec::new();
    let mut extended: Vec<(String, String)> = Vec::new();
    let mut segs: Vec<(String, Vec<Segment>)> = Vec::new();

    for (name, value) in raw {
        match classify(&name) {
            Some((base, Some(n), ext)) => {
                let seg = Segment { no: SegNo::new(n), extended: ext, value };
                match segs.iter_mut().find(|(b, _)| b == base) {
                    Some((_, v)) => v.push(seg),
                    None => segs.push((base.to_string(), vec![seg])),
                }
            }
            Some((base, None, _)) => extended.push((base.to_string(), value)),
            None => plain.push((name, value)),
        }
    }

    let mut out = HashMap::new();
    for (name, value) in plain {
        out.insert(name, decode_unstructured(&value));
    }
    for (base, value) in extended {
        out.insert(base, decode_extended(&value));
    }
    for (base, mut list) in segs {
        // Stable sort keeps appearance order among equal numbers.
        list.sort_by(|a, b| a.no.cmp(&b.no));
        list.dedup_by(|later, earlier| later.no == earlier.no);
        let mut cs = "us-ascii".to_string();
        let mut bytes = Vec::new();
        for seg in &list {
            if seg.extended {
                if seg.no.is_zero() {
                    let (c, text) = split_extended(&seg.value);
                    cs = c;
                    bytes.extend(percent_decode(text));
                } else {
                    bytes.extend(percent_decode(&seg.value));
                }
            } else {
                bytes.extend_from_slice(seg.value.as_bytes());
            }
        }
        out.insert(base, charset::decode(&bytes, &cs));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filename(params: &str) -> Option<String> {
        Structured::parse(&format!("attachment; {params}")).param("filename").map(String::from)
    }

    #[test]
    fn rfc2231_examples() {
        let cases: &[(&str, &str)] = &[
            ("filename=\"report.pdf\"", "report.pdf"),
            ("filename*=utf-8''a%C3%A9.txt", "aé.txt"),
            ("filename*0=\"long\"; filename*1=\"name.txt\"", "longname.txt"),
            ("filename*0*=utf-8''a%C3%A9; filename*1=\".txt\"", "aé.txt"),
            ("filename=\"=?utf-8?Q?a=C3=A9.txt?=\"", "aé.txt"),
            ("filename=two words.bin", "two words.bin"),
            ("filename*=''caf%E9.txt", "caf\u{FFFD}.txt"),
            ("filename*0=a; filename*2=c; filename*10=j", "acj"),
            ("filename=\"a\\\\\"; x=1", "a\\"),
        ];
        for (params, want) in cases {
            assert_eq!(filename(params).as_deref(), Some(*want), "{params}");
        }
    }

    #[test]
    fn precedence_and_duplicates() {
        assert_eq!(filename("filename=a; filename*=utf-8''b").as_deref(), Some("b"));
        assert_eq!(filename("filename*=utf-8''b; filename*0=c").as_deref(), Some("c"));
        assert_eq!(filename("filename=a; filename=b").as_deref(), Some("a"));
        assert_eq!(filename("filename*0=a; filename*00=b").as_deref(), Some("a"));
        assert_eq!(filename("filename*1=x; filename*1*=y").as_deref(), Some("x"));
        assert_eq!(filename("*0=a").as_deref(), None);
    }

    #[test]
    fn segments_and_quotes() {
        let s = Structured::parse(" Multipart/Mixed ; boundary=\"a;b\"; x");
        assert_eq!(s.value_lower(), "multipart/mixed");
        assert_eq!(s.param("boundary"), Some("a;b"));
        let s = Structured::parse("x; a=\"unclosed; b=1");
        assert_eq!(s.param("a"), Some("unclosed; b=1"));
        assert_eq!(s.param("b"), None);
    }
}
