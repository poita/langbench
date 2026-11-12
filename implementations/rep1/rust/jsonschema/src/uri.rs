//! RFC 3986 reference resolution and RFC 6901 JSON Pointer helpers.

/// A URI reference split into its five components (RFC 3986 §3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UriRef<'a> {
    /// The scheme, without the trailing `:`.
    pub scheme: Option<&'a str>,
    /// The authority, without the leading `//`.
    pub authority: Option<&'a str>,
    /// The path (possibly empty).
    pub path: &'a str,
    /// The query, without the leading `?`.
    pub query: Option<&'a str>,
    /// The fragment, without the leading `#`.
    pub fragment: Option<&'a str>,
}

fn is_scheme(s: &str) -> bool {
    let mut chars = s.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
}

/// Splits a URI reference into components.
pub fn split(s: &str) -> UriRef<'_> {
    let (rest, fragment) = match s.split_once('#') {
        Some((r, f)) => (r, Some(f)),
        None => (s, None),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((r, q)) => (r, Some(q)),
        None => (rest, None),
    };
    let mut scheme = None;
    let mut rest = rest;
    if let Some(i) = rest.find(':') {
        if is_scheme(&rest[..i]) {
            scheme = Some(&rest[..i]);
            rest = &rest[i + 1..];
        }
    }
    let mut authority = None;
    if let Some(r) = rest.strip_prefix("//") {
        let end = r.find('/').unwrap_or(r.len());
        authority = Some(&r[..end]);
        rest = &r[end..];
    }
    UriRef {
        scheme,
        authority,
        path: rest,
        query,
        fragment,
    }
}

/// Reassembles components into a string (RFC 3986 §5.3).
pub fn recompose(u: &UriRef<'_>) -> String {
    let mut out = String::new();
    if let Some(s) = u.scheme {
        out.push_str(s);
        out.push(':');
    }
    if let Some(a) = u.authority {
        out.push_str("//");
        out.push_str(a);
    }
    out.push_str(u.path);
    if let Some(q) = u.query {
        out.push('?');
        out.push_str(q);
    }
    if let Some(f) = u.fragment {
        out.push('#');
        out.push_str(f);
    }
    out
}

/// RFC 3986 §5.2.4: removes `.` and `..` segments from a path.
pub fn remove_dot_segments(path: &str) -> String {
    let mut input = path;
    let mut out = String::new();
    while !input.is_empty() {
        if let Some(r) = input.strip_prefix("../") {
            input = r;
        } else if let Some(r) = input.strip_prefix("./") {
            input = r;
        } else if input.starts_with("/./") {
            input = &input[2..];
        } else if input == "/." {
            input = "/";
        } else if input.starts_with("/../") {
            input = &input[3..];
            pop_segment(&mut out);
        } else if input == "/.." {
            input = "/";
            pop_segment(&mut out);
        } else if input == "." || input == ".." {
            input = "";
        } else {
            let start = usize::from(input.starts_with('/'));
            let end = input[start..].find('/').map_or(input.len(), |i| i + start);
            out.push_str(&input[..end]);
            input = &input[end..];
        }
    }
    out
}

fn pop_segment(out: &mut String) {
    match out.rfind('/') {
        Some(i) => out.truncate(i),
        None => out.clear(),
    }
}

/// Resolves `reference` against `base` (RFC 3986 §5.2.2, strict).
///
/// ```
/// use jsonschema::uri::resolve;
/// assert_eq!(resolve("http://a/b/c/d;p?q", "../g"), "http://a/b/g");
/// assert_eq!(resolve("", "foo.json#x"), "foo.json#x");
/// ```
pub fn resolve(base: &str, reference: &str) -> String {
    let b = split(base);
    let r = split(reference);
    if r.scheme.is_some() {
        recompose(&UriRef {
            path: &remove_dot_segments(r.path),
            ..r
        })
    } else if r.authority.is_some() {
        recompose(&UriRef {
            scheme: b.scheme,
            authority: r.authority,
            path: &remove_dot_segments(r.path),
            query: r.query,
            fragment: r.fragment,
        })
    } else {
        let (path, query) = if r.path.is_empty() {
            (b.path.to_string(), r.query.or(b.query))
        } else if r.path.starts_with('/') {
            (remove_dot_segments(r.path), r.query)
        } else {
            (remove_dot_segments(&merge(&b, r.path)), r.query)
        };
        recompose(&UriRef {
            scheme: b.scheme,
            authority: b.authority,
            path: &path,
            query,
            fragment: r.fragment,
        })
    }
}

fn merge(base: &UriRef<'_>, ref_path: &str) -> String {
    if base.authority.is_some() && base.path.is_empty() {
        format!("/{ref_path}")
    } else {
        match base.path.rfind('/') {
            Some(i) => format!("{}{}", &base.path[..=i], ref_path),
            None => ref_path.to_string(),
        }
    }
}

/// Splits `uri` at the first `#` into the part before it and the fragment.
pub fn split_fragment(uri: &str) -> (&str, Option<&str>) {
    match uri.split_once('#') {
        Some((d, f)) => (d, Some(f)),
        None => (uri, None),
    }
}

/// Returns `uri` with any fragment removed.
pub fn strip_fragment(uri: &str) -> &str {
    split_fragment(uri).0
}

/// Decodes `%XX` escapes, interpreting the result as UTF-8 (invalid
/// sequences become U+FFFD).
pub fn percent_decode(s: &str) -> String {
    if !s.contains('%') {
        return s.to_string();
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(b: u8) -> Option<u8> {
    (b as char).to_digit(16).map(|d| d as u8)
}

/// Escapes a reference token for use in a JSON Pointer (`~` → `~0`,
/// `/` → `~1`).
pub fn pointer_escape(token: &str) -> String {
    token.replace('~', "~0").replace('/', "~1")
}

/// Reverses [`pointer_escape`].
pub fn pointer_unescape(token: &str) -> String {
    token.replace("~1", "/").replace("~0", "~")
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 3986 §5.4.1 normal examples.
    #[test]
    fn rfc_normal_examples() {
        let base = "http://a/b/c/d;p?q";
        let cases = [
            ("g:h", "g:h"),
            ("g", "http://a/b/c/g"),
            ("./g", "http://a/b/c/g"),
            ("g/", "http://a/b/c/g/"),
            ("/g", "http://a/g"),
            ("//g", "http://g"),
            ("?y", "http://a/b/c/d;p?y"),
            ("g?y", "http://a/b/c/g?y"),
            ("#s", "http://a/b/c/d;p?q#s"),
            ("g#s", "http://a/b/c/g#s"),
            ("g?y#s", "http://a/b/c/g?y#s"),
            (";x", "http://a/b/c/;x"),
            ("", "http://a/b/c/d;p?q"),
            (".", "http://a/b/c/"),
            ("./", "http://a/b/c/"),
            ("..", "http://a/b/"),
            ("../", "http://a/b/"),
            ("../g", "http://a/b/g"),
            ("../..", "http://a/"),
            ("../../", "http://a/"),
            ("../../g", "http://a/g"),
        ];
        for (r, want) in cases {
            assert_eq!(resolve(base, r), want, "ref {r:?}");
        }
    }

    // RFC 3986 §5.4.2 abnormal examples.
    #[test]
    fn rfc_abnormal_examples() {
        let base = "http://a/b/c/d;p?q";
        let cases = [
            ("../../../g", "http://a/g"),
            ("../../../../g", "http://a/g"),
            ("/./g", "http://a/g"),
            ("/../g", "http://a/g"),
            ("g.", "http://a/b/c/g."),
            (".g", "http://a/b/c/.g"),
            ("g..", "http://a/b/c/g.."),
            ("..g", "http://a/b/c/..g"),
            ("./../g", "http://a/b/g"),
            ("./g/.", "http://a/b/c/g/"),
            ("g/./h", "http://a/b/c/g/h"),
            ("g/../h", "http://a/b/c/h"),
            ("g;x=1/./y", "http://a/b/c/g;x=1/y"),
            ("g;x=1/../y", "http://a/b/c/y"),
            ("g?y/./x", "http://a/b/c/g?y/./x"),
            ("g#s/../x", "http://a/b/c/g#s/../x"),
            ("http:g", "http:g"),
        ];
        for (r, want) in cases {
            assert_eq!(resolve(base, r), want, "ref {r:?}");
        }
    }

    #[test]
    fn empty_and_opaque_bases() {
        assert_eq!(resolve("", "#foo"), "#foo");
        assert_eq!(resolve("", "foo.json"), "foo.json");
        assert_eq!(resolve("urn:example:root", "#/$defs/a"), "urn:example:root#/$defs/a");
        assert_eq!(
            resolve("urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed", "urn:uuid:other#x"),
            "urn:uuid:other#x"
        );
        assert_eq!(resolve("http://x.test", "foo"), "http://x.test/foo");
    }

    #[test]
    fn fragments() {
        assert_eq!(split_fragment("a#b#c"), ("a", Some("b#c")));
        assert_eq!(strip_fragment("http://x/y#"), "http://x/y");
        assert_eq!(percent_decode("a%25b%2Fc%C3%A9"), "a%b/cé");
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz"), "%zz");
        assert_eq!(percent_decode("%4"), "%4");
    }

    #[test]
    fn pointer_tokens() {
        assert_eq!(pointer_escape("a/b~c"), "a~1b~0c");
        assert_eq!(pointer_unescape("a~1b~0c"), "a/b~c");
        assert_eq!(pointer_unescape("~01"), "~1");
    }
}
