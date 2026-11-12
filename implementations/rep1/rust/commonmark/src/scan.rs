//! Small hand-written scanners for block starts, autolinks and link titles.
//!
//! Every scanner starts at a given position and examines only as many bytes
//! as it needs to reach its verdict.

use crate::node::ListData;
use crate::text::{is_punct, is_space_or_tab};

/// `#{1,6}` followed by spaces/tabs or the end of the line. Returns the level
/// and the number of bytes to consume (the hashes plus the whitespace).
pub(crate) fn atx_heading_start(s: &[u8], pos: usize) -> Option<(u8, usize)> {
    let mut i = pos;
    while i < s.len() && s[i] == b'#' {
        i += 1;
        if i - pos > 6 {
            return None;
        }
    }
    let level = i - pos;
    if level == 0 {
        return None;
    }
    if i == s.len() {
        return Some((level as u8, level));
    }
    if !is_space_or_tab(s[i]) {
        return None;
    }
    while i < s.len() && is_space_or_tab(s[i]) {
        i += 1;
    }
    Some((level as u8, i - pos))
}

/// An opening code fence: three or more backticks (with no backtick in the
/// rest of the line) or tildes. Returns the fence character and run length.
pub(crate) fn open_code_fence(s: &[u8], pos: usize) -> Option<(u8, usize)> {
    let c = *s.get(pos)?;
    if c != b'`' && c != b'~' {
        return None;
    }
    let mut i = pos;
    while i < s.len() && s[i] == c {
        i += 1;
    }
    let n = i - pos;
    if n < 3 {
        return None;
    }
    if c == b'`' && s[i..].contains(&b'`') {
        return None;
    }
    Some((c, n))
}

/// A closing code fence of character `c`: a run of `c` followed only by
/// spaces and tabs. Returns the run length, or 0.
pub(crate) fn close_code_fence(s: &[u8], pos: usize, c: u8) -> usize {
    let mut i = pos;
    while i < s.len() && s[i] == c {
        i += 1;
    }
    let n = i - pos;
    while i < s.len() && is_space_or_tab(s[i]) {
        i += 1;
    }
    if i == s.len() {
        n
    } else {
        0
    }
}

/// A setext underline: a run of `=` (level 1) or `-` (level 2) followed only
/// by spaces and tabs.
pub(crate) fn setext_level(s: &[u8], pos: usize) -> Option<u8> {
    let c = *s.get(pos)?;
    let level = match c {
        b'=' => 1,
        b'-' => 2,
        _ => return None,
    };
    let mut i = pos;
    while i < s.len() && s[i] == c {
        i += 1;
    }
    while i < s.len() && is_space_or_tab(s[i]) {
        i += 1;
    }
    (i == s.len()).then_some(level)
}

/// Three or more `*`, `_` or `-` (all the same) mixed with spaces and tabs.
///
/// On failure returns the position of the byte that ruled it out (or the end
/// of the line when there were too few characters); any later scan on the same
/// line that starts before that position is bound to fail as well.
pub(crate) fn thematic_break(s: &[u8], pos: usize) -> Result<(), usize> {
    let c = match s.get(pos) {
        Some(&c @ (b'*' | b'_' | b'-')) => c,
        _ => return Err(pos),
    };
    let mut count = 0;
    for (i, &b) in s.iter().enumerate().skip(pos) {
        if b == c {
            count += 1;
        } else if !is_space_or_tab(b) {
            return Err(i);
        }
    }
    if count >= 3 {
        Ok(())
    } else {
        Err(s.len())
    }
}

/// Parses a list marker at `pos`. Returns the marker width and list data.
/// `interrupts_paragraph` applies the extra restrictions for a marker that
/// would interrupt a paragraph.
pub(crate) fn list_marker(s: &[u8], pos: usize, interrupts_paragraph: bool) -> Option<(usize, ListData)> {
    let at = |i: usize| s.get(i).copied();
    let blank_after = |mut i: usize| {
        while i < s.len() && is_space_or_tab(s[i]) {
            i += 1;
        }
        i >= s.len()
    };
    let is_ws_or_end = |i: usize| match at(i) {
        None => true,
        Some(b) => is_space_or_tab(b),
    };
    let c = at(pos)?;
    if matches!(c, b'*' | b'-' | b'+') {
        if !is_ws_or_end(pos + 1) {
            return None;
        }
        if interrupts_paragraph && blank_after(pos + 1) {
            return None;
        }
        return Some((
            1,
            ListData { ordered: false, marker: c as char, start: 0, tight: true },
        ));
    }
    if c.is_ascii_digit() {
        let mut i = pos;
        let mut start: u32 = 0;
        while i < s.len() && s[i].is_ascii_digit() && i - pos < 9 {
            start = start * 10 + (s[i] - b'0') as u32;
            i += 1;
        }
        let d = at(i)?;
        if d != b'.' && d != b')' {
            return None;
        }
        if !is_ws_or_end(i + 1) {
            return None;
        }
        if interrupts_paragraph && (start != 1 || blank_after(i + 1)) {
            return None;
        }
        return Some((
            i + 1 - pos,
            ListData { ordered: true, marker: d as char, start, tight: true },
        ));
    }
    None
}

/// Result of scanning an autolink body.
pub(crate) struct Autolink {
    /// Length of the text between `<` and `>`.
    pub len: usize,
    /// `true` for an email address (needs a `mailto:` prefix).
    pub email: bool,
}

/// Scans an autolink starting right after a `<`. On success the `>` is at
/// `s[len]`.
pub(crate) fn autolink(s: &[u8]) -> Option<Autolink> {
    uri_autolink(s).or_else(|| email_autolink(s))
}

fn uri_autolink(s: &[u8]) -> Option<Autolink> {
    if !s.first()?.is_ascii_alphabetic() {
        return None;
    }
    let mut i = 1;
    while i < s.len() && (s[i].is_ascii_alphanumeric() || matches!(s[i], b'.' | b'+' | b'-')) {
        i += 1;
    }
    // 1..=31 scheme characters after the first letter, then a colon.
    if !(2..=32).contains(&i) || s.get(i) != Some(&b':') {
        return None;
    }
    i += 1;
    while i < s.len() && s[i] > b' ' && s[i] != b'<' && s[i] != b'>' {
        i += 1;
    }
    (s.get(i) == Some(&b'>')).then_some(Autolink { len: i, email: false })
}

fn email_autolink(s: &[u8]) -> Option<Autolink> {
    let is_local = |b: u8| {
        b.is_ascii_alphanumeric()
            || matches!(
                b,
                b'.' | b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'*' | b'+' | b'/' | b'=' | b'?'
                    | b'^' | b'_' | b'`' | b'{' | b'|' | b'}' | b'~' | b'-'
            )
    };
    let mut i = 0;
    while i < s.len() && is_local(s[i]) {
        i += 1;
    }
    if i == 0 || s.get(i) != Some(&b'@') {
        return None;
    }
    i += 1;
    loop {
        let start = i;
        while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'-') {
            i += 1;
        }
        let label = &s[start..i];
        if label.is_empty()
            || label.len() > 63
            || !label[0].is_ascii_alphanumeric()
            || !label[label.len() - 1].is_ascii_alphanumeric()
        {
            return None;
        }
        match s.get(i) {
            Some(b'.') => i += 1,
            Some(b'>') => return Some(Autolink { len: i, email: true }),
            _ => return None,
        }
    }
}

/// Scans a link title starting at `pos` (which holds `"`, `'` or `(`).
/// Returns the position just after the closing delimiter. The title is the
/// longest match in which the closing delimiter (and for `(`, also `(`) occurs
/// inside only directly after a backslash.
pub(crate) fn link_title(s: &[u8], pos: usize) -> Option<usize> {
    let open = *s.get(pos)?;
    let close = match open {
        b'"' => b'"',
        b'\'' => b'\'',
        b'(' => b')',
        _ => return None,
    };
    let mut best = None;
    let mut i = pos + 1;
    while i < s.len() {
        let b = s[i];
        let escaped = i > pos + 1 && s[i - 1] == b'\\';
        if b == close {
            best = Some(i + 1);
            if !escaped {
                break;
            }
        } else if open == b'(' && b == b'(' && !escaped {
            break;
        }
        i += 1;
    }
    best
}

/// Scans a link destination at `pos` (after leading whitespace). Returns the
/// raw destination range and the position after it (after the `>` for the
/// bracketed form).
pub(crate) fn link_destination(s: &[u8], pos: usize) -> Option<(usize, usize, usize)> {
    let len = s.len();
    if s.get(pos) == Some(&b'<') {
        let mut i = pos + 1;
        loop {
            if i >= len {
                return None;
            }
            match s[i] {
                b'>' => break,
                b'\\' => i += 2,
                b'\n' | b'<' => return None,
                _ => i += 1,
            }
        }
        // s[i] == '>'
        return Some((pos + 1, i, i + 1));
    }
    let mut i = pos;
    let mut parens = 0usize;
    while i < len {
        let b = s[i];
        if b == b'\\' && i + 1 < len && is_punct(s[i + 1]) {
            i += 2;
        } else if b == b'(' {
            parens += 1;
            i += 1;
            if parens > 32 {
                return None;
            }
        } else if b == b')' {
            if parens == 0 {
                break;
            }
            parens -= 1;
            i += 1;
        } else if crate::text::is_space(b) {
            break;
        } else {
            i += 1;
        }
    }
    if i >= len || parens != 0 {
        return None;
    }
    Some((pos, i, i))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn autolinks() {
        assert!(autolink(b"http://a.b/?x=1>").is_some());
        assert!(autolink(b"a:b>").is_none()); // scheme too short
        assert!(autolink(b"ab:>").is_some());
        assert!(autolink(b"foo@bar.example.com>").unwrap().email);
        assert!(autolink(b"foo@-bar.com>").is_none());
        assert!(autolink(b"foo bar:x>").is_none());
        assert!(autolink(b"http://a b>").is_none());
    }

    #[test]
    fn titles() {
        assert_eq!(link_title(br#""a\"b" c"#, 0), Some(6));
        assert_eq!(link_title(br#""a\\" c""#, 0), Some(8));
        assert_eq!(link_title(b"(a(b)", 0), None);
        assert_eq!(link_title(b"(a\\)b)", 0), Some(6));
    }

    #[test]
    fn block_starts() {
        assert_eq!(atx_heading_start(b"## x", 0), Some((2, 3)));
        assert_eq!(atx_heading_start(b"#######", 0), None);
        assert_eq!(atx_heading_start(b"#x", 0), None);
        assert!(thematic_break(b"- - -", 0).is_ok());
        assert!(thematic_break(b"--", 0).is_err());
        assert_eq!(thematic_break(b"-- x", 0), Err(3));
        assert_eq!(setext_level(b"==  ", 0), Some(1));
        assert_eq!(open_code_fence(b"``` a`", 0), None);
        assert_eq!(open_code_fence(b"~~~ a`", 0), Some((b'~', 3)));
    }
}
