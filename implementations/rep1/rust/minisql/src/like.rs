//! `LIKE` pattern matching.

/// Matches `text` against the `LIKE` pattern `pattern`.
///
/// `%` matches any run of characters, `_` exactly one character; letters
/// match case-insensitively for ASCII only. The whole text must match.
///
/// This is the classic greedy wildcard matcher with a single backtrack
/// point (the most recent `%`), so it runs in `O(|text| · |pattern|)` time
/// and constant extra space. It works on UTF-8 bytes but always advances
/// over whole characters when `_` or a backtrack consumes input.
///
/// ```
/// use minisql::like::like;
/// assert!(like("Apple", "a%LE"));
/// assert!(!like("é", "É"));
/// assert!(like("é", "_"));
/// ```
pub fn like(text: &str, pattern: &str) -> bool {
    let s = text.as_bytes();
    let p = pattern.as_bytes();
    let (mut si, mut pi) = (0usize, 0usize);
    // After the last `%`: (pattern index following it, text index to retry from).
    let mut star: Option<(usize, usize)> = None;
    while si < s.len() {
        if pi < p.len() {
            match p[pi] {
                b'%' => {
                    pi += 1;
                    star = Some((pi, si));
                    continue;
                }
                b'_' => {
                    si += char_len(s[si]).min(s.len() - si);
                    pi += 1;
                    continue;
                }
                c if c.eq_ignore_ascii_case(&s[si]) => {
                    si += 1;
                    pi += 1;
                    continue;
                }
                _ => {}
            }
        }
        match star {
            Some((sp, ss)) => {
                let next = ss + char_len(s[ss]).min(s.len() - ss);
                star = Some((sp, next));
                pi = sp;
                si = next;
            }
            None => return false,
        }
    }
    while pi < p.len() && p[pi] == b'%' {
        pi += 1;
    }
    pi == p.len()
}

fn char_len(lead: u8) -> usize {
    match lead {
        0..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::like;

    #[test]
    fn basics() {
        assert!(like("abc", "abc"));
        assert!(like("abc", "a%"));
        assert!(like("abc", "%c"));
        assert!(like("abc", "%"));
        assert!(like("", "%"));
        assert!(like("", ""));
        assert!(!like("", "_"));
        assert!(like("abc", "a_c"));
        assert!(!like("abc", "a_"));
        assert!(like("Ab_c", "ab%"));
        assert!(like("APPLE", "apple"));
        assert!(like("12345", "12%"));
    }

    #[test]
    fn backtracking() {
        assert!(like("aaab", "%a%b"));
        assert!(like("abcabc", "%abc"));
        assert!(!like("abcab", "%abc"));
        assert!(like("mississippi", "m%iss%pi"));
        assert!(!like("mississippi", "m%iss%pa"));
        assert!(like("xyz", "%%%z"));
    }

    #[test]
    fn unicode() {
        assert!(!like("É", "é"));
        assert!(like("é", "_"));
        assert!(!like("é", "__"));
        assert!(like("aéb", "a_b"));
        assert!(like("aéb", "%b"));
        assert!(like("éé", "%é"));
        assert!(like("éa", "%a"));
    }

    #[test]
    fn pathological_is_fast() {
        let s = "a".repeat(5000);
        let p = format!("{}b", "%a".repeat(50));
        assert!(!like(&s, &p));
    }
}
