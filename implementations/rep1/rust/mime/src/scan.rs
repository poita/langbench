//! Small scanning helpers shared by the header-value parsers.

/// Whether `c` is SPACE or TAB.
pub fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// Strips leading and trailing SPACE and TAB characters.
pub fn strip_blanks(s: &str) -> &str {
    s.trim_matches(is_blank)
}

/// Scans a quoted string whose opening `"` is at `chars[open]`.
///
/// Returns the unescaped contents and the index just past the closing quote
/// (or `chars.len()` if the string is never closed). A `\` and the character
/// after it stand for that character; a final lone `\` stands for itself.
pub fn quoted_string(chars: &[char], open: usize) -> (String, usize) {
    let mut out = String::new();
    let mut i = open + 1;
    while i < chars.len() {
        match chars[i] {
            '"' => return (out, i + 1),
            '\\' if i + 1 < chars.len() => {
                out.push(chars[i + 1]);
                i += 2;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    (out, chars.len())
}

/// Skips a comment whose opening `(` is at `chars[open]`; returns the index
/// just past the matching `)`, or `chars.len()` if it is unterminated.
pub fn skip_comment(chars: &[char], open: usize) -> usize {
    let mut depth = 0usize;
    let mut i = open;
    while i < chars.len() {
        match chars[i] {
            '\\' if i + 1 < chars.len() => i += 2,
            '(' => {
                depth += 1;
                i += 1;
            }
            ')' => {
                depth -= 1;
                i += 1;
                if depth == 0 {
                    return i;
                }
            }
            _ => i += 1,
        }
    }
    chars.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cv(s: &str) -> Vec<char> {
        s.chars().collect()
    }

    #[test]
    fn quoted() {
        assert_eq!(quoted_string(&cv(r#""a\\" x"#), 0), ("a\\".to_string(), 5));
        assert_eq!(quoted_string(&cv("\"abc"), 0), ("abc".to_string(), 4));
        assert_eq!(quoted_string(&cv("\"ab\\"), 0), ("ab\\".to_string(), 4));
    }

    #[test]
    fn comments() {
        assert_eq!(skip_comment(&cv("(a (b) c) d"), 0), 9);
        assert_eq!(skip_comment(&cv(r"(a \) b"), 0), 7);
        assert_eq!(skip_comment(&cv("(a(b)"), 0), 5);
    }
}
