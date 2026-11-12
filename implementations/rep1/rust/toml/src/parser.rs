//! The TOML decoder: a single-pass recursive-descent parser.

use crate::datetime;
use crate::error::ParseError;
use crate::number;
use crate::tables::{ArrayNode, Conflict, Node, State, TableNode};
use crate::value::{Scalar, ScalarKind, Value};

/// Maximum nesting of arrays and inline tables before the parser gives up
/// (protects the call stack from adversarial input). Deeply nested documents
/// near this limit need a few MB of stack; the CLI runs on a large one.
const MAX_DEPTH: usize = 2_000;

/// Parses a TOML 1.0.0 document given as bytes, validating UTF-8 first.
pub(crate) fn parse_bytes(input: &[u8]) -> Result<Value, ParseError> {
    let text = std::str::from_utf8(input).map_err(|e| {
        ParseError::at(input, e.valid_up_to(), "invalid UTF-8")
    })?;
    if text.starts_with('\u{FEFF}') {
        return Err(ParseError::at(input, 0, "byte-order mark is not allowed"));
    }
    // A CR is only ever valid as part of CRLF, wherever it appears.
    for (i, &b) in input.iter().enumerate() {
        if b == b'\r' && input.get(i + 1) != Some(&b'\n') {
            return Err(ParseError::at(input, i, "bare carriage return"));
        }
    }
    Parser { src: input, pos: 0 }.document()
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
}

type Res<T> = Result<T, ParseError>;

fn is_bare_key_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// Bytes that may appear in a number / date-time token.
fn is_token_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'+' | b'-' | b'.' | b':')
}

impl<'a> Parser<'a> {
    fn err<T>(&self, msg: &str) -> Res<T> {
        Err(ParseError::at(self.src, self.pos, msg))
    }

    fn conflict<T>(&self, c: Conflict) -> Res<T> {
        self.err(c.0)
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn peek_at(&self, n: usize) -> Option<u8> {
        self.src.get(self.pos + n).copied()
    }

    fn starts_with(&self, s: &[u8]) -> bool {
        self.src[self.pos..].starts_with(s)
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t')) {
            self.pos += 1;
        }
    }

    /// Consumes `\n` or `\r\n` if present.
    fn eat_newline(&mut self) -> bool {
        match self.peek() {
            Some(b'\n') => {
                self.pos += 1;
                true
            }
            Some(b'\r') if self.peek_at(1) == Some(b'\n') => {
                self.pos += 2;
                true
            }
            _ => false,
        }
    }

    /// Skips a comment starting at `#`, up to (not including) the newline.
    fn skip_comment(&mut self) -> Res<()> {
        debug_assert_eq!(self.peek(), Some(b'#'));
        self.pos += 1;
        while let Some(b) = self.peek() {
            match b {
                b'\n' => break,
                b'\r' if self.peek_at(1) == Some(b'\n') => break,
                b'\t' | 0x20..=0x7E | 0x80..=0xFF => self.pos += 1,
                _ => return self.err("control character in comment"),
            }
        }
        Ok(())
    }

    /// After a statement: optional whitespace and comment, then newline or EOF.
    fn end_of_line(&mut self) -> Res<()> {
        self.skip_ws();
        if self.peek() == Some(b'#') {
            self.skip_comment()?;
        }
        if self.peek().is_none() || self.eat_newline() {
            Ok(())
        } else {
            self.err("unexpected characters after statement")
        }
    }

    // ---- document ------------------------------------------------------

    fn document(&mut self) -> Res<Value> {
        let mut root = TableNode::new(State::Explicit);
        // The table that key/value pairs are currently added to.
        let mut cur: &mut TableNode = &mut root;
        loop {
            self.skip_ws();
            match self.peek() {
                None => break,
                Some(b'#') => {
                    self.skip_comment()?;
                    self.end_of_line()?;
                }
                Some(b'\n' | b'\r') => {
                    self.eat_newline();
                }
                Some(b'[') => {
                    let is_array = self.peek_at(1) == Some(b'[');
                    self.pos += if is_array { 2 } else { 1 };
                    let path = self.key()?;
                    self.skip_ws();
                    if self.peek() != Some(b']') {
                        return self.err("expected ']'");
                    }
                    self.pos += 1;
                    if is_array {
                        if self.peek() != Some(b']') {
                            return self.err("expected ']]'");
                        }
                        self.pos += 1;
                    }
                    let opened = if is_array {
                        root.open_array_table(&path)
                    } else {
                        root.open_table(&path)
                    };
                    cur = match opened {
                        Ok(t) => t,
                        Err(c) => return self.conflict(c),
                    };
                    self.end_of_line()?;
                }
                Some(_) => {
                    let path = self.key()?;
                    self.skip_ws();
                    if self.peek() != Some(b'=') {
                        return self.err("expected '='");
                    }
                    self.pos += 1;
                    self.skip_ws();
                    let value = self.value(0)?;
                    if let Err(c) = cur.insert_dotted(&path, value) {
                        return self.conflict(c);
                    }
                    self.end_of_line()?;
                }
            }
        }
        Ok(root.into_value_root())
    }

    // ---- keys ----------------------------------------------------------

    /// Parses a (possibly dotted) key.
    fn key(&mut self) -> Res<Vec<String>> {
        let mut parts = Vec::new();
        loop {
            self.skip_ws();
            parts.push(self.simple_key()?);
            self.skip_ws();
            if self.peek() == Some(b'.') {
                self.pos += 1;
            } else {
                return Ok(parts);
            }
        }
    }

    fn simple_key(&mut self) -> Res<String> {
        match self.peek() {
            Some(b'"') => self.basic_string(),
            Some(b'\'') => self.literal_string(),
            Some(b) if is_bare_key_byte(b) => {
                let start = self.pos;
                while self.peek().is_some_and(is_bare_key_byte) {
                    self.pos += 1;
                }
                // Bare keys are ASCII, so this is always valid UTF-8.
                Ok(String::from_utf8_lossy(&self.src[start..self.pos]).into_owned())
            }
            _ => self.err("expected a key"),
        }
    }

    // ---- values --------------------------------------------------------

    fn value(&mut self, depth: usize) -> Res<Node> {
        if depth > MAX_DEPTH {
            return self.err("nesting too deep");
        }
        match self.peek() {
            None => self.err("expected a value"),
            Some(b'"') => {
                let s = if self.starts_with(b"\"\"\"") {
                    self.multiline_basic_string()?
                } else {
                    self.basic_string()?
                };
                Ok(Node::Scalar(Scalar::new(ScalarKind::String, s)))
            }
            Some(b'\'') => {
                let s = if self.starts_with(b"'''") {
                    self.multiline_literal_string()?
                } else {
                    self.literal_string()?
                };
                Ok(Node::Scalar(Scalar::new(ScalarKind::String, s)))
            }
            Some(b'[') => self.array(depth),
            Some(b'{') => self.inline_table(depth),
            Some(_) => self.scalar_token(),
        }
    }

    /// Booleans, numbers and date-times.
    fn scalar_token(&mut self) -> Res<Node> {
        let start = self.pos;
        while self.peek().is_some_and(is_token_byte) {
            self.pos += 1;
        }
        // "YYYY-MM-DD HH…": a space only joins a date and a time when a time
        // (two digits) follows it.
        if self.pos - start == 10
            && self.peek() == Some(b' ')
            && self.peek_at(1).is_some_and(|b| b.is_ascii_digit())
            && self.peek_at(2).is_some_and(|b| b.is_ascii_digit())
        {
            self.pos += 1;
            while self.peek().is_some_and(is_token_byte) {
                self.pos += 1;
            }
        }
        let tok = match std::str::from_utf8(&self.src[start..self.pos]) {
            Ok(t) if !t.is_empty() => t,
            _ => return self.err("expected a value"),
        };
        let b = tok.as_bytes();
        let scalar = if tok == "true" || tok == "false" {
            Some(Scalar::new(ScalarKind::Bool, tok))
        } else if (b.len() >= 5 && b[4] == b'-' && b[..4].iter().all(u8::is_ascii_digit))
            || (b.len() >= 3 && b[2] == b':')
        {
            datetime::parse(tok)
        } else if let Some(i) = number::parse_integer(tok) {
            Some(Scalar::new(ScalarKind::Integer, i.to_string()))
        } else {
            number::parse_float(tok)
                .map(|f| Scalar::new(ScalarKind::Float, number::format_float(f)))
        };
        match scalar {
            Some(s) => Ok(Node::Scalar(s)),
            None => {
                self.pos = start;
                self.err("invalid value")
            }
        }
    }

    /// Skips whitespace, newlines and comments (inside arrays).
    fn skip_filler(&mut self) -> Res<()> {
        loop {
            self.skip_ws();
            match self.peek() {
                Some(b'#') => self.skip_comment()?,
                Some(b'\n' | b'\r') => {
                    self.eat_newline();
                }
                _ => return Ok(()),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Res<Node> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        loop {
            self.skip_filler()?;
            if self.peek() == Some(b']') {
                self.pos += 1;
                break;
            }
            items.push(self.value(depth + 1)?);
            self.skip_filler()?;
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                _ => return self.err("expected ',' or ']' in array"),
            }
        }
        Ok(Node::Array(ArrayNode {
            items,
            of_tables: false,
        }))
    }

    fn inline_table(&mut self, depth: usize) -> Res<Node> {
        self.pos += 1; // '{'
        let mut table = TableNode::new(State::Dotted);
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
        } else {
            loop {
                let path = self.key()?;
                self.skip_ws();
                if self.peek() != Some(b'=') {
                    return self.err("expected '=' in inline table");
                }
                self.pos += 1;
                self.skip_ws();
                let value = self.value(depth + 1)?;
                if let Err(c) = table.insert_dotted(&path, value) {
                    return self.conflict(c);
                }
                self.skip_ws();
                match self.peek() {
                    Some(b',') => self.pos += 1,
                    Some(b'}') => {
                        self.pos += 1;
                        break;
                    }
                    _ => return self.err("expected ',' or '}' in inline table"),
                }
            }
        }
        table.state = State::Inline;
        Ok(Node::Table(table))
    }

    // ---- strings -------------------------------------------------------

    fn finish_string(&self, buf: Vec<u8>) -> Res<String> {
        String::from_utf8(buf).or_else(|_| self.err("invalid UTF-8 in string"))
    }

    /// Checks one unescaped byte of a string body.
    fn check_plain(&self, b: u8) -> Res<()> {
        if (b < 0x20 && b != b'\t') || b == 0x7F {
            self.err("control character in string")
        } else {
            Ok(())
        }
    }

    fn hex(&mut self, digits: usize) -> Res<char> {
        let mut v: u32 = 0;
        for _ in 0..digits {
            let d = match self.peek().and_then(|b| (b as char).to_digit(16)) {
                Some(d) => d,
                None => return self.err("invalid unicode escape"),
            };
            v = v * 16 + d;
            self.pos += 1;
        }
        match char::from_u32(v) {
            Some(c) => Ok(c),
            None => self.err("escape is not a unicode scalar value"),
        }
    }

    /// Handles the escape after a backslash (the backslash is consumed).
    fn escape(&mut self, buf: &mut Vec<u8>) -> Res<()> {
        let c = match self.peek() {
            Some(c) => c,
            None => return self.err("unterminated escape"),
        };
        self.pos += 1;
        let simple = match c {
            b'b' => 0x08,
            b't' => b'\t',
            b'n' => b'\n',
            b'f' => 0x0C,
            b'r' => b'\r',
            b'"' => b'"',
            b'\\' => b'\\',
            b'u' | b'U' => {
                let ch = self.hex(if c == b'u' { 4 } else { 8 })?;
                let mut tmp = [0u8; 4];
                buf.extend_from_slice(ch.encode_utf8(&mut tmp).as_bytes());
                return Ok(());
            }
            _ => {
                self.pos -= 1;
                return self.err("invalid escape sequence");
            }
        };
        buf.push(simple);
        Ok(())
    }

    fn basic_string(&mut self) -> Res<String> {
        self.pos += 1; // opening quote
        let mut buf = Vec::new();
        loop {
            match self.peek() {
                None => return self.err("unterminated string"),
                Some(b'"') => {
                    self.pos += 1;
                    return self.finish_string(buf);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    self.escape(&mut buf)?;
                }
                Some(b) => {
                    self.check_plain(b)?;
                    buf.push(b);
                    self.pos += 1;
                }
            }
        }
    }

    fn literal_string(&mut self) -> Res<String> {
        self.pos += 1;
        let mut buf = Vec::new();
        loop {
            match self.peek() {
                None => return self.err("unterminated string"),
                Some(b'\'') => {
                    self.pos += 1;
                    return self.finish_string(buf);
                }
                Some(b) => {
                    self.check_plain(b)?;
                    buf.push(b);
                    self.pos += 1;
                }
            }
        }
    }

    /// Counts the run of `q` bytes at the cursor.
    fn quote_run(&self, q: u8) -> usize {
        self.src[self.pos..].iter().take_while(|&&b| b == q).count()
    }

    fn multiline_basic_string(&mut self) -> Res<String> {
        self.pos += 3;
        self.eat_newline();
        let mut buf = Vec::new();
        loop {
            match self.peek() {
                None => return self.err("unterminated string"),
                Some(b'"') => {
                    let run = self.quote_run(b'"');
                    self.pos += run;
                    if run >= 3 {
                        if run > 5 {
                            return self.err("too many quotes");
                        }
                        buf.extend(std::iter::repeat(b'"').take(run - 3));
                        return self.finish_string(buf);
                    }
                    buf.extend(std::iter::repeat(b'"').take(run));
                }
                Some(b'\\') => {
                    self.pos += 1;
                    // Line-ending backslash?
                    let mut j = self.pos;
                    while matches!(self.src.get(j), Some(b' ' | b'\t')) {
                        j += 1;
                    }
                    let at_newline = match self.src.get(j) {
                        Some(b'\n') => true,
                        Some(b'\r') => self.src.get(j + 1) == Some(&b'\n'),
                        _ => false,
                    };
                    if at_newline {
                        self.pos = j;
                        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
                            self.pos += 1;
                        }
                    } else {
                        self.escape(&mut buf)?;
                    }
                }
                Some(b'\r') => self.pos += 1, // CRLF → LF (the LF is kept next)
                Some(b'\n') => {
                    buf.push(b'\n');
                    self.pos += 1;
                }
                Some(b) => {
                    self.check_plain(b)?;
                    buf.push(b);
                    self.pos += 1;
                }
            }
        }
    }

    fn multiline_literal_string(&mut self) -> Res<String> {
        self.pos += 3;
        self.eat_newline();
        let mut buf = Vec::new();
        loop {
            match self.peek() {
                None => return self.err("unterminated string"),
                Some(b'\'') => {
                    let run = self.quote_run(b'\'');
                    self.pos += run;
                    if run >= 3 {
                        if run > 5 {
                            return self.err("too many quotes");
                        }
                        buf.extend(std::iter::repeat(b'\'').take(run - 3));
                        return self.finish_string(buf);
                    }
                    buf.extend(std::iter::repeat(b'\'').take(run));
                }
                Some(b'\r') => self.pos += 1,
                Some(b'\n') => {
                    buf.push(b'\n');
                    self.pos += 1;
                }
                Some(b) => {
                    self.check_plain(b)?;
                    buf.push(b);
                    self.pos += 1;
                }
            }
        }
    }
}

impl TableNode {
    fn into_value_root(self) -> Value {
        Value::Table(self.into_table())
    }
}
