//! Recursive-descent parser for command lines (spec §6, §17.1).

use std::collections::BTreeMap;

use crate::command::{Command, ScanOptions};
use crate::error::{Error, Result};
use crate::lexer::{lex, Token};
use crate::path::Path;
use crate::predicate::{CmpOp, Pred};
use crate::value::Value;
use crate::{MAX_DEPTH, MAX_KEY, MAX_LIMIT};

/// Parses one command line.
///
/// Errors follow the stage order of the spec: lexing first, then the command
/// word, then the rest of the line left to right.
///
/// ```
/// use tessera::{parse_command, Command};
/// assert_eq!(parse_command("begin"), Ok(Command::Begin));
/// assert!(parse_command("frobnicate").is_err());
/// ```
pub fn parse_command(line: &str) -> Result<Command> {
    let toks = lex(line)?;
    let mut p = Parser { toks, pos: 0 };
    let cmd = p.command()?;
    if p.pos != p.toks.len() {
        return Err(Error::Syntax);
    }
    Ok(cmd)
}

struct Parser {
    toks: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, n: usize) -> Option<&Token> {
        self.toks.get(self.pos + n)
    }

    fn next(&mut self) -> Option<Token> {
        let t = self.toks.get(self.pos).cloned();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn peek_word(&self, w: &str) -> bool {
        matches!(self.peek(), Some(Token::Word(x)) if x == w)
    }

    fn expect_punct(&mut self, c: u8) -> Result<()> {
        match self.next() {
            Some(Token::Punct(x)) if x == c => Ok(()),
            _ => Err(Error::Syntax),
        }
    }

    fn expect_word(&mut self, w: &str) -> Result<()> {
        match self.next() {
            Some(Token::Word(x)) if x == w => Ok(()),
            _ => Err(Error::Syntax),
        }
    }

    fn command(&mut self) -> Result<Command> {
        let word = match self.next() {
            Some(Token::Word(w)) => w,
            _ => return Err(Error::Syntax),
        };
        Ok(match word.as_str() {
            "begin" => Command::Begin,
            "commit" => Command::Commit,
            "rollback" => Command::Rollback,
            "checkpoint" => Command::Checkpoint,
            "stat" => Command::Stat,
            "indexes" => Command::Indexes,
            "put" => {
                let key = self.key()?;
                let value = self.value(1)?;
                Command::Put { key, value }
            }
            "get" => Command::Get { key: self.key()? },
            "delete" => Command::Delete { key: self.key()? },
            "update" => {
                let key = self.key()?;
                let path = self.path()?;
                let value = self.value(1)?;
                Command::Update { key, path, value }
            }
            "unset" => {
                let key = self.key()?;
                let path = self.path()?;
                Command::Unset { key, path }
            }
            "scan" => self.scan()?,
            "find" => {
                let pred = self.pred()?;
                let mut limit = None;
                if self.peek_word("limit") {
                    self.pos += 1;
                    limit = Some(self.limit()?);
                }
                Command::Find { pred, limit }
            }
            "create" => {
                self.expect_word("index")?;
                Command::CreateIndex(self.path()?)
            }
            "drop" => {
                self.expect_word("index")?;
                Command::DropIndex(self.path()?)
            }
            _ => return Err(Error::UnknownCommand),
        })
    }

    /// A string token resolved to text.
    fn string(&mut self) -> Result<String> {
        match self.next() {
            Some(Token::Str(Some(s))) => Ok(s),
            Some(Token::Str(None)) => Err(Error::BadUtf8),
            _ => Err(Error::Syntax),
        }
    }

    fn key(&mut self) -> Result<Vec<u8>> {
        let s = self.string()?;
        if s.is_empty() || s.len() > MAX_KEY {
            return Err(Error::BadKey);
        }
        Ok(s.into_bytes())
    }

    fn limit(&mut self) -> Result<u32> {
        match self.next() {
            Some(Token::Int(None)) => Err(Error::IntRange),
            Some(Token::Int(Some(n))) => {
                if (0..=MAX_LIMIT as i64).contains(&n) {
                    Ok(n as u32)
                } else {
                    Err(Error::Syntax)
                }
            }
            _ => Err(Error::Syntax),
        }
    }

    fn scan(&mut self) -> Result<Command> {
        let mut o = ScanOptions::default();
        let (mut has_from, mut has_to, mut has_limit) = (false, false, false);
        while let Some(Token::Word(w)) = self.peek().cloned() {
            self.pos += 1;
            match w.as_str() {
                "from" if !has_from => {
                    has_from = true;
                    o.from = Some(self.string()?.into_bytes());
                }
                "to" if !has_to => {
                    has_to = true;
                    o.to = Some(self.string()?.into_bytes());
                }
                "limit" if !has_limit => {
                    has_limit = true;
                    o.limit = Some(self.limit()?);
                }
                "reverse" if !o.reverse => o.reverse = true,
                "keys" if !o.keys_only => o.keys_only = true,
                _ => return Err(Error::Syntax),
            }
        }
        Ok(Command::Scan(o))
    }

    /// `path = WORD { "." WORD }`, with the limits checked per segment.
    fn path(&mut self) -> Result<Path> {
        let mut path = Path::empty();
        match self.next() {
            Some(Token::Word(w)) => path.push_segment(&w)?,
            _ => return Err(Error::Syntax),
        }
        while matches!(self.peek(), Some(Token::Punct(b'.'))) {
            self.pos += 1;
            match self.next() {
                Some(Token::Word(w)) => path.push_segment(&w)?,
                _ => return Err(Error::Syntax),
            }
        }
        Ok(path)
    }

    /// Parses a value that is at nesting `level` (the whole literal is level 1).
    fn value(&mut self, level: usize) -> Result<Value> {
        if level > MAX_DEPTH {
            return Err(Error::Depth);
        }
        match self.next() {
            Some(Token::Word(w)) => match w.as_str() {
                "null" => Ok(Value::Null),
                "true" => Ok(Value::Bool(true)),
                "false" => Ok(Value::Bool(false)),
                _ => Err(Error::Syntax),
            },
            Some(Token::Int(Some(n))) => Ok(Value::Int(n)),
            Some(Token::Int(None)) => Err(Error::IntRange),
            Some(Token::Str(Some(s))) => Ok(Value::Str(s)),
            Some(Token::Str(None)) => Err(Error::BadUtf8),
            Some(Token::Punct(b'[')) => self.list(level),
            Some(Token::Punct(b'{')) => self.object(level),
            _ => Err(Error::Syntax),
        }
    }

    fn list(&mut self, level: usize) -> Result<Value> {
        let mut items = Vec::new();
        if matches!(self.peek(), Some(Token::Punct(b']'))) {
            self.pos += 1;
            return Ok(Value::List(items));
        }
        loop {
            items.push(self.value(level + 1)?);
            match self.next() {
                Some(Token::Punct(b',')) => {}
                Some(Token::Punct(b']')) => return Ok(Value::List(items)),
                _ => return Err(Error::Syntax),
            }
        }
    }

    fn object(&mut self, level: usize) -> Result<Value> {
        let mut fields = BTreeMap::new();
        if matches!(self.peek(), Some(Token::Punct(b'}'))) {
            self.pos += 1;
            return Ok(Value::Object(fields));
        }
        loop {
            let name = match self.next() {
                Some(Token::Word(w)) => w,
                Some(Token::Str(Some(s))) => s,
                Some(Token::Str(None)) => return Err(Error::BadUtf8),
                _ => return Err(Error::Syntax),
            };
            if fields.contains_key(&name) {
                return Err(Error::DupField);
            }
            self.expect_punct(b':')?;
            let v = self.value(level + 1)?;
            fields.insert(name, v);
            match self.next() {
                Some(Token::Punct(b',')) => {}
                Some(Token::Punct(b'}')) => return Ok(Value::Object(fields)),
                _ => return Err(Error::Syntax),
            }
        }
    }

    fn pred(&mut self) -> Result<Pred> {
        let mut left = self.conj()?;
        while self.peek_word("or") {
            self.pos += 1;
            let right = self.conj()?;
            left = Pred::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn conj(&mut self) -> Result<Pred> {
        let mut left = self.term()?;
        while self.peek_word("and") {
            self.pos += 1;
            let right = self.term()?;
            left = Pred::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn term(&mut self) -> Result<Pred> {
        match self.peek().cloned() {
            Some(Token::Punct(b'(')) => {
                self.pos += 1;
                let p = self.pred()?;
                self.expect_punct(b')')?;
                Ok(p)
            }
            Some(Token::Word(w)) => {
                let next_is_word = matches!(self.peek_at(1), Some(Token::Word(_)));
                if w == "not" && matches!(self.peek_at(1), Some(Token::Punct(b'('))) {
                    self.pos += 2;
                    let p = self.pred()?;
                    self.expect_punct(b')')?;
                    Ok(Pred::Not(Box::new(p)))
                } else if w == "exists" && next_is_word {
                    self.pos += 1;
                    Ok(Pred::Exists(self.path()?))
                } else if w == "missing" && next_is_word {
                    self.pos += 1;
                    Ok(Pred::Missing(self.path()?))
                } else {
                    let path = self.path()?;
                    let op: CmpOp = match self.next() {
                        Some(Token::Op(op)) => op,
                        _ => return Err(Error::Syntax),
                    };
                    let v = self.value(1)?;
                    Ok(Pred::Cmp(path, op, v))
                }
            }
            _ => Err(Error::Syntax),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nest(open: &str, n: usize) -> String {
        open.repeat(n)
    }

    #[test]
    fn simple_commands() {
        assert_eq!(parse_command("  begin\t"), Ok(Command::Begin));
        assert_eq!(parse_command("begin 1"), Err(Error::Syntax));
        assert_eq!(parse_command(""), Err(Error::Syntax));
        assert_eq!(parse_command("1"), Err(Error::Syntax));
        assert_eq!(parse_command("PUT"), Err(Error::UnknownCommand));
        assert_eq!(parse_command(r#"frobnicate "\ud800""#), Err(Error::UnknownCommand));
    }

    #[test]
    fn put_values() {
        let c = parse_command(r#"put "k" {b:[1,"x",null], a:true}"#).unwrap();
        match c {
            Command::Put { key, value } => {
                assert_eq!(key, b"k");
                assert_eq!(value.render(), r#"{"a":true,"b":[1,"x",null]}"#);
            }
            _ => panic!(),
        }
        assert_eq!(parse_command(r#"put "a""#), Err(Error::Syntax));
        assert_eq!(parse_command("put 1 \"x\""), Err(Error::Syntax));
        assert_eq!(parse_command(r#"put "" 1"#), Err(Error::BadKey));
        assert_eq!(parse_command(r#"put "\ud800" 1"#), Err(Error::BadUtf8));
        assert_eq!(parse_command(r#"put "a" [1,]"#), Err(Error::Syntax));
        assert_eq!(parse_command(r#"put "a" {x:1,x}"#), Err(Error::DupField));
        assert_eq!(parse_command(r#"put "a" {x:1,x 2}"#), Err(Error::DupField));
        assert_eq!(parse_command(r#"put "a" 9223372036854775808"#), Err(Error::IntRange));
        assert_eq!(parse_command(r#"put "a" 1 99999999999999999999"#), Err(Error::Syntax));
        assert_eq!(parse_command(r#"get "a" "\ud800""#), Err(Error::Syntax));
    }

    #[test]
    fn depth_is_checked_before_the_next_token() {
        let ok = format!("put \"a\" {}{}", nest("[", 32), nest("]", 32));
        assert!(parse_command(&ok).is_ok());
        for tail in ["1]", "99999999999999999999", "\"\\ud800\"", ",", ")", ""] {
            let line = format!("put \"a\" {}{}", nest("[", 32), tail);
            assert_eq!(parse_command(&line), Err(Error::Depth), "{tail}");
        }
        let line = format!("put \"a\" {}{{x:[[1]],x:1}}", nest("[", 30));
        assert_eq!(parse_command(&line), Err(Error::Depth));
        let line = format!("put \"a\" {}{{x:1,x:[[1]]}}", nest("[", 30));
        assert_eq!(parse_command(&line), Err(Error::DupField));
        let line = format!("put \"a\" {}-", nest("[", 32));
        assert_eq!(parse_command(&line), Err(Error::Syntax));
    }

    #[test]
    fn paths() {
        match parse_command("unset \"a\" a . b.c").unwrap() {
            Command::Unset { path, .. } => assert_eq!(path.text(), "a.b.c"),
            _ => panic!(),
        }
        assert_eq!(parse_command("create index a.b.c.d.e.f.g.h.i."), Err(Error::BadPath));
        assert_eq!(parse_command(&format!("create index {} .", "x".repeat(31))), Err(Error::BadPath));
        assert_eq!(parse_command("create index a."), Err(Error::Syntax));
        assert_eq!(parse_command("create thing a"), Err(Error::Syntax));
    }

    #[test]
    fn scan_options() {
        match parse_command(r#"scan from "" to "z" limit 3 reverse keys"#).unwrap() {
            Command::Scan(o) => {
                assert_eq!(o.from, Some(vec![]));
                assert_eq!(o.to, Some(b"z".to_vec()));
                assert_eq!(o.limit, Some(3));
                assert!(o.reverse && o.keys_only);
            }
            _ => panic!(),
        }
        assert_eq!(parse_command("scan reverse reverse"), Err(Error::Syntax));
        assert_eq!(parse_command("scan limit -1"), Err(Error::Syntax));
        assert_eq!(parse_command("scan limit 2147483648"), Err(Error::Syntax));
        assert_eq!(parse_command("scan limit 9223372036854775808"), Err(Error::IntRange));
        assert!(parse_command("scan limit 2147483647").is_ok());
        assert_eq!(parse_command("scan bogus"), Err(Error::Syntax));
        assert_eq!(parse_command("scan 5"), Err(Error::Syntax));
    }

    #[test]
    fn predicates() {
        let c = parse_command(r#"find a == 1 or b > 2 and not(c == 3) limit 5"#).unwrap();
        match c {
            Command::Find { pred, limit } => {
                assert_eq!(limit, Some(5));
                assert!(matches!(pred, Pred::Or(_, _)));
            }
            _ => panic!(),
        }
        assert!(matches!(
            parse_command("find exists a.b").unwrap(),
            Command::Find { pred: Pred::Exists(_), .. }
        ));
        // `exists` not followed by a word is an ordinary path.
        assert!(matches!(
            parse_command("find exists == 1").unwrap(),
            Command::Find { pred: Pred::Cmp(..), .. }
        ));
        assert_eq!(parse_command("find a == 1 and"), Err(Error::Syntax));
        assert_eq!(parse_command("find"), Err(Error::Syntax));
        assert_eq!(parse_command("find a = 1"), Err(Error::Syntax));
        assert_eq!(parse_command("find a == 1 bogus"), Err(Error::Syntax));
        assert_eq!(parse_command("find (a == 1"), Err(Error::Syntax));
    }
}
