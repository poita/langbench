//! Git's default path quoting.

/// Quotes a path the way `git ls-tree` and `git diff` print it by default.
///
/// A name made only of printable ASCII other than `"` and `\` is returned
/// unchanged; otherwise it is wrapped in double quotes with C-style escapes
/// and three-digit octal escapes for other bytes.
pub fn quote_path(name: &[u8]) -> Vec<u8> {
    if name.iter().all(|&b| (0x20..=0x7e).contains(&b) && b != b'"' && b != b'\\') {
        return name.to_vec();
    }
    let mut out = vec![b'"'];
    for &b in name {
        match b {
            0x07 => out.extend_from_slice(b"\\a"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x09 => out.extend_from_slice(b"\\t"),
            0x0a => out.extend_from_slice(b"\\n"),
            0x0b => out.extend_from_slice(b"\\v"),
            0x0c => out.extend_from_slice(b"\\f"),
            0x0d => out.extend_from_slice(b"\\r"),
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b if b < 0x20 || b >= 0x7f => {
                out.extend_from_slice(format!("\\{:03o}", b).as_bytes());
            }
            b => out.push(b),
        }
    }
    out.push(b'"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(s: &[u8]) -> String {
        String::from_utf8(quote_path(s)).unwrap()
    }

    #[test]
    fn plain_names_are_untouched() {
        assert_eq!(q(b"dir/file name-1.txt"), "dir/file name-1.txt");
        assert_eq!(q(b""), "");
    }

    #[test]
    fn special_names_are_quoted() {
        assert_eq!(q("café.txt".as_bytes()), "\"caf\\303\\251.txt\"");
        assert_eq!(q(b"quote\"and\\slash.txt"), "\"quote\\\"and\\\\slash.txt\"");
        assert_eq!(q(b"a\tb\nc\x01\x7f"), "\"a\\tb\\nc\\001\\177\"");
    }
}
