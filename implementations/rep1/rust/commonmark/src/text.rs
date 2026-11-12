//! Character classes and text-level helpers shared by the parsers and the
//! renderer: entity decoding, backslash-escape removal, HTML escaping and URL
//! encoding.

/// The `cmark_isspace` set: space, tab, LF, VT, FF, CR.
#[inline]
pub(crate) fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// Exactly a space or a tab.
#[inline]
pub(crate) fn is_space_or_tab(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

/// ASCII punctuation: `` !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~ ``.
#[inline]
pub(crate) fn is_punct(b: u8) -> bool {
    b.is_ascii_punctuation()
}

/// Trims the [`is_space`] set from both ends.
pub(crate) fn trim(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_ascii() && is_space(c as u8))
}

/// Trims the [`is_space`] set from the end.
pub(crate) fn trim_end(s: &str) -> &str {
    s.trim_end_matches(|c: char| c.is_ascii() && is_space(c as u8))
}

/// Tries to match an entity reference at the start of `s`, which must begin
/// with `&`. Only numeric references and `&amp; &lt; &gt; &quot;` are
/// recognised. Returns the decoded character and the number of bytes matched.
pub(crate) fn match_entity(s: &[u8]) -> Option<(char, usize)> {
    debug_assert_eq!(s.first(), Some(&b'&'));
    match s.get(1)? {
        b'#' => {
            let (radix, start, max_digits) = match s.get(2) {
                Some(b'x') | Some(b'X') => (16u32, 3usize, 6usize),
                _ => (10, 2, 7),
            };
            let mut i = start;
            let mut value: u32 = 0;
            while i < s.len() && i - start < max_digits {
                match (s[i] as char).to_digit(radix) {
                    Some(d) => value = value * radix + d,
                    None => break,
                }
                i += 1;
            }
            if i == start || s.get(i) != Some(&b';') {
                return None;
            }
            let ch = match char::from_u32(value) {
                Some(c) if c != '\0' => c,
                _ => '\u{FFFD}',
            };
            Some((ch, i + 1))
        }
        b'a' if s[2..].starts_with(b"mp;") => Some(('&', 5)),
        b'l' if s[2..].starts_with(b"t;") => Some(('<', 4)),
        b'g' if s[2..].starts_with(b"t;") => Some(('>', 4)),
        b'q' if s[2..].starts_with(b"uot;") => Some(('"', 6)),
        _ => None,
    }
}

/// Replaces every recognised entity reference in `s` by the character it
/// stands for.
pub(crate) fn decode_entities(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'&' {
            if let Some((ch, len)) = match_entity(&bytes[i..]) {
                out.push_str(&s[last..i]);
                out.push(ch);
                i += len;
                last = i;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&s[last..]);
    out
}

/// Removes the backslash from every backslash-escaped ASCII punctuation
/// character.
pub(crate) fn unescape_backslashes(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() && is_punct(bytes[i + 1]) {
            out.push_str(&s[last..i]);
            last = i + 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    out.push_str(&s[last..]);
    out
}

/// Normalises a link destination: trim, decode entities, remove escapes.
pub(crate) fn clean_url(raw: &str) -> String {
    unescape_backslashes(&decode_entities(trim(raw)))
}

/// Normalises a link title (already stripped of its delimiters).
pub(crate) fn clean_title(raw: &str) -> String {
    unescape_backslashes(&decode_entities(raw))
}

/// Appends `s` to `out`, escaping `& < > "`.
pub(crate) fn escape_html(out: &mut String, s: &str) {
    let mut last = 0;
    for (i, b) in s.bytes().enumerate() {
        let rep = match b {
            b'&' => "&amp;",
            b'<' => "&lt;",
            b'>' => "&gt;",
            b'"' => "&quot;",
            _ => continue,
        };
        out.push_str(&s[last..i]);
        out.push_str(rep);
        last = i + 1;
    }
    out.push_str(&s[last..]);
}

fn starts_with_ci(s: &str, prefix: &str) -> bool {
    s.len() >= prefix.len() && s.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
}

/// Whether a destination uses a scheme that is rendered as an empty `href`.
pub(crate) fn is_unsafe_url(url: &str) -> bool {
    const BAD: [&str; 4] = ["javascript:", "vbscript:", "file:", "data:"];
    const OK_DATA: [&str; 4] = [
        "data:image/png",
        "data:image/gif",
        "data:image/jpeg",
        "data:image/webp",
    ];
    if !BAD.iter().any(|p| starts_with_ci(url, p)) {
        return false;
    }
    !OK_DATA.iter().any(|p| starts_with_ci(url, p))
}

/// Appends the URL-encoded form of `url` to `out`.
pub(crate) fn encode_href(out: &mut String, url: &str) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for b in url.bytes() {
        let safe = b.is_ascii_alphanumeric()
            || matches!(
                b,
                b'-' | b'_'
                    | b'.'
                    | b'~'
                    | b'!'
                    | b'#'
                    | b'$'
                    | b'%'
                    | b'('
                    | b')'
                    | b'*'
                    | b'+'
                    | b','
                    | b'/'
                    | b':'
                    | b';'
                    | b'='
                    | b'?'
                    | b'@'
            );
        if safe {
            out.push(b as char);
            continue;
        }
        match b {
            b'&' => out.push_str("&amp;"),
            b'\'' => out.push_str("&#x27;"),
            _ => {
                out.push('%');
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 15) as usize] as char);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entities() {
        assert_eq!(decode_entities("a &amp; b &lt;&gt;&quot; &#65;&#x42;"), "a & b <>\" AB");
        assert_eq!(decode_entities("&#0; &#xD800; &#1114112;"), "\u{FFFD} \u{FFFD} \u{FFFD}");
        assert_eq!(decode_entities("&#12345678; &#; &#x; &foo; &amp"), "&#12345678; &#; &#x; &foo; &amp");
        assert_eq!(decode_entities("&AMP;"), "&AMP;");
    }

    #[test]
    fn escapes() {
        assert_eq!(unescape_backslashes(r"\*a\b\\"), r"*a\b\");
        assert_eq!(clean_url(r"  \&amp;  "), "&");
        assert_eq!(clean_url("&#92;*"), "*");
    }

    #[test]
    fn html_escape() {
        let mut s = String::new();
        escape_html(&mut s, "<a href=\"x\">&'</a>");
        assert_eq!(s, "&lt;a href=&quot;x&quot;&gt;&amp;'&lt;/a&gt;");
    }

    #[test]
    fn href() {
        let mut s = String::new();
        encode_href(&mut s, "/a b?x=1&y='é'[]%20");
        assert_eq!(s, "/a%20b?x=1&amp;y=&#x27;%C3%A9&#x27;%5B%5D%20");
        assert!(is_unsafe_url("JavaScript:alert(1)"));
        assert!(is_unsafe_url("data:text/html,x"));
        assert!(!is_unsafe_url("data:image/png;base64,xx"));
        assert!(!is_unsafe_url("/javascript:x"));
    }
}
