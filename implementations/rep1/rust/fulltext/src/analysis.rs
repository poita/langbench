//! Text analysis: tokenising, case folding, stop words and stemming.
//!
//! Documents and queries go through the same pipeline: [`tokenize`] finds the
//! tokens, [`fold`] normalises their text, and [`term_for`] produces the index
//! term (the Porter stem for pure-ASCII-letter tokens, the folded text
//! otherwise).

use crate::stemmer::stem;

/// A token found in a text, with its byte span in the original string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    /// Byte offset of the first byte of the token.
    pub start: usize,
    /// Byte offset one past the last byte of the token.
    pub end: usize,
}

/// The 33 stop words, sorted so they can be binary searched.
const STOP_WORDS: [&str; 33] = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it",
    "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these",
    "they", "this", "to", "was", "will", "with",
];

/// Returns true if `c` is a token character (ASCII alphanumerics, Latin
/// letters U+00C0..U+024F except × and ÷, Greek and Cyrillic).
pub fn is_token_char(c: char) -> bool {
    matches!(c,
        '0'..='9' | 'A'..='Z' | 'a'..='z'
        | '\u{C0}'..='\u{D6}' | '\u{D8}'..='\u{F6}' | '\u{F8}'..='\u{24F}'
        | '\u{370}'..='\u{3FF}' | '\u{400}'..='\u{4FF}')
}

/// Returns true for the apostrophes U+0027 and U+2019.
pub fn is_apostrophe(c: char) -> bool {
    c == '\'' || c == '\u{2019}'
}

/// Returns true for the seven whitespace code points the format recognises:
/// tab, LF, VT, FF, CR, space and U+00A0.
pub fn is_space(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\u{B}' | '\u{C}' | '\r' | ' ' | '\u{A0}')
}

/// Splits `text` into tokens.
///
/// A token is one or more token characters, optionally continued by
/// apostrophes that sit between token characters. Everything else separates
/// tokens.
pub fn tokenize(text: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut chars = text.char_indices().peekable();
    while let Some((start, c)) = chars.next() {
        if !is_token_char(c) {
            continue;
        }
        let mut end = start + c.len_utf8();
        // Scan the rest of the token.
        loop {
            match chars.peek().copied() {
                Some((i, n)) if is_token_char(n) => {
                    end = i + n.len_utf8();
                    chars.next();
                }
                Some((i, n)) if is_apostrophe(n) => {
                    // The apostrophe must be followed by a token character.
                    let after = i + n.len_utf8();
                    match text[after..].chars().next() {
                        Some(f) if is_token_char(f) => {
                            chars.next(); // the apostrophe
                            chars.next(); // the following token character
                            end = after + f.len_utf8();
                        }
                        _ => break,
                    }
                }
                _ => break,
            }
        }
        tokens.push(Token { start, end });
    }
    tokens
}

/// Folds token text: removes apostrophes and lower-cases ASCII letters.
pub fn fold(token: &str) -> String {
    token
        .chars()
        .filter(|&c| !is_apostrophe(c))
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// Returns true if the folded token text is one of the stop words.
pub fn is_stop_word(folded: &str) -> bool {
    STOP_WORDS.binary_search(&folded).is_ok()
}

/// Maps folded token text to its index term: the Porter stem when the text is
/// only ASCII letters, the text itself otherwise.
pub fn term_for(folded: &str) -> String {
    if folded.bytes().all(|b| b.is_ascii_lowercase()) {
        stem(folded)
    } else {
        folded.to_string()
    }
}

/// Tokenises `text` and returns the terms of its tokens, in order, together
/// with the folded text of each token.
pub fn analyze(text: &str) -> Vec<(Token, String)> {
    tokenize(text)
        .into_iter()
        .map(|t| {
            let term = term_for(&fold(&text[t.start..t.end]));
            (t, term)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(text: &str) -> Vec<&str> {
        tokenize(text).iter().map(|t| &text[t.start..t.end]).collect()
    }

    #[test]
    fn spec_tokenizer_examples() {
        assert_eq!(toks("The cat sat."), ["The", "cat", "sat"]);
        assert_eq!(toks("don't stop"), ["don't", "stop"]);
        assert_eq!(toks("'quoted'"), ["quoted"]);
        assert_eq!(toks("rock'n'roll"), ["rock'n'roll"]);
        assert_eq!(toks("a''b"), ["a", "b"]);
        assert_eq!(toks("well-known"), ["well", "known"]);
        assert_eq!(toks("Version 1.2.3"), ["Version", "1", "2", "3"]);
        assert_eq!(toks("X1 XY2Z"), ["X1", "XY2Z"]);
        assert_eq!(toks("Don\u{2019}t"), ["Don\u{2019}t"]);
    }

    #[test]
    fn separators() {
        assert_eq!(toks("a\u{D7}b a\u{F7}b"), ["a", "b", "a", "b"]);
        assert_eq!(toks("日本語 abc"), ["abc"]);
        assert_eq!(toks("naïve Ωmega Привет"), ["naïve", "Ωmega", "Привет"]);
    }

    #[test]
    fn folding_is_ascii_only() {
        assert_eq!(fold("Café"), "café");
        assert_eq!(fold("CAFÉ"), "cafÉ");
        assert_eq!(fold("Don\u{2019}t"), "dont");
        assert_eq!(fold("don't"), "dont");
    }

    #[test]
    fn terms() {
        assert_eq!(term_for("running"), "run");
        assert_eq!(term_for("x1s"), "x1s");
        assert_eq!(term_for("café"), "café");
    }

    #[test]
    fn stop_words() {
        assert!(is_stop_word("the"));
        assert!(is_stop_word("with"));
        assert!(!is_stop_word("cat"));
        assert!(STOP_WORDS.windows(2).all(|w| w[0] < w[1]));
    }
}
