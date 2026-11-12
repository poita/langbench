//! Parser for the query language (SPEC Part 4).
//!
//! A query line is one of `.tables`, `.schema <table>`, `COUNT <table>`,
//! `SELECT ...` or `INDEX <index> <literal>`. Parsing is a single pass over
//! the bytes of the line.

use crate::error::{Error, Result};
use crate::value::Value;

/// Comparison operators allowed in a `WHERE` condition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// `=`
    Eq,
    /// `!=`
    Ne,
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
    /// `IS`
    Is,
    /// `IS NOT`
    IsNot,
}

/// `<column> <op> <literal>`.
#[derive(Debug, Clone, PartialEq)]
pub struct Condition {
    /// Column name as written.
    pub column: String,
    /// Operator.
    pub op: Op,
    /// The literal operand, before affinity is applied.
    pub literal: Value,
}

/// The select list.
#[derive(Debug, Clone, PartialEq)]
pub enum Columns {
    /// `*`
    All,
    /// Explicit column names.
    Named(Vec<String>),
}

/// A parsed `SELECT` statement.
#[derive(Debug, Clone, PartialEq)]
pub struct Select {
    /// The select list.
    pub columns: Columns,
    /// Table name as written.
    pub table: String,
    /// `AND`-joined conditions.
    pub conditions: Vec<Condition>,
    /// `ORDER BY` column and whether it is descending.
    pub order_by: Option<(String, bool)>,
    /// `LIMIT` row count.
    pub limit: Option<u64>,
}

/// A parsed query line.
#[derive(Debug, Clone, PartialEq)]
pub enum Query {
    /// `.tables`
    Tables,
    /// `.schema <table>`
    Schema(String),
    /// `COUNT <table>`
    Count(String),
    /// `SELECT ...`
    Select(Select),
    /// `INDEX <index> <literal>`
    Index {
        /// Index name as written.
        name: String,
        /// The key literal, before affinity is applied.
        literal: Value,
    },
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_ident(word: &str) -> bool {
    let b = word.as_bytes();
    !b.is_empty() && (b[0].is_ascii_alphabetic() || b[0] == b'_')
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.s.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t')) {
            self.pos += 1;
        }
    }

    /// Read a maximal run of word bytes (no whitespace skipping).
    fn word(&mut self) -> &'a str {
        let start = self.pos;
        while self.peek().is_some_and(is_word_byte) {
            self.pos += 1;
        }
        // Word bytes are ASCII, so this slice is valid UTF-8.
        std::str::from_utf8(&self.s[start..self.pos]).unwrap_or("")
    }

    /// Consume the keyword `kw` if it is the next word.
    fn try_kw(&mut self, kw: &str) -> bool {
        let save = self.pos;
        self.skip_ws();
        if self.word().eq_ignore_ascii_case(kw) {
            true
        } else {
            self.pos = save;
            false
        }
    }

    fn expect_kw(&mut self, kw: &str) -> Result<()> {
        if self.try_kw(kw) {
            Ok(())
        } else {
            Err(Error::syntax(format!("expected {kw}")))
        }
    }

    fn ident(&mut self) -> Result<String> {
        self.skip_ws();
        let w = self.word();
        if is_ident(w) {
            Ok(w.to_string())
        } else {
            Err(Error::syntax("expected an identifier"))
        }
    }

    fn expect_end(&mut self) -> Result<()> {
        self.skip_ws();
        if self.pos == self.s.len() {
            Ok(())
        } else {
            Err(Error::syntax("unexpected trailing text"))
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.pos;
        while self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.pos += 1;
        }
        self.pos - start
    }

    fn literal(&mut self) -> Result<Value> {
        self.skip_ws();
        match self.peek() {
            Some(b'\'') => self.string_literal().map(Value::Text),
            Some(b'x' | b'X') if self.s.get(self.pos + 1) == Some(&b'\'') => self.blob_literal(),
            Some(b'+' | b'-' | b'0'..=b'9') => self.numeral(),
            Some(b) if is_word_byte(b) => {
                if self.word().eq_ignore_ascii_case("NULL") {
                    Ok(Value::Null)
                } else {
                    Err(Error::syntax("malformed literal"))
                }
            }
            _ => Err(Error::syntax("expected a literal")),
        }
    }

    fn string_literal(&mut self) -> Result<String> {
        self.pos += 1; // opening quote
        let mut out = Vec::new();
        loop {
            match self.peek() {
                None => return Err(Error::syntax("unterminated string")),
                Some(b'\'') => {
                    if self.s.get(self.pos + 1) == Some(&b'\'') {
                        out.push(b'\'');
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                        break;
                    }
                }
                Some(b) => {
                    out.push(b);
                    self.pos += 1;
                }
            }
        }
        String::from_utf8(out).map_err(|_| Error::syntax("invalid UTF-8 in string"))
    }

    fn blob_literal(&mut self) -> Result<Value> {
        self.pos += 2; // X'
        let mut digits = Vec::new();
        loop {
            match self.peek() {
                Some(b'\'') => {
                    self.pos += 1;
                    break;
                }
                Some(b) if b.is_ascii_hexdigit() => {
                    digits.push(b);
                    self.pos += 1;
                }
                _ => return Err(Error::syntax("malformed blob literal")),
            }
        }
        if digits.len() % 2 != 0 {
            return Err(Error::syntax("odd number of hex digits"));
        }
        let hex = |b: u8| (b as char).to_digit(16).unwrap_or(0) as u8;
        Ok(Value::Blob(
            digits.chunks(2).map(|p| hex(p[0]) << 4 | hex(p[1])).collect(),
        ))
    }

    fn numeral(&mut self) -> Result<Value> {
        let start = self.pos;
        if matches!(self.peek(), Some(b'+' | b'-')) {
            self.pos += 1;
        }
        if self.digits() == 0 {
            return Err(Error::syntax("malformed numeral"));
        }
        let mut is_real = false;
        if self.peek() == Some(b'.') {
            is_real = true;
            self.pos += 1;
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            let save = self.pos;
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if self.digits() == 0 {
                self.pos = save;
            } else {
                is_real = true;
            }
        }
        if self.peek().is_some_and(is_word_byte) {
            return Err(Error::syntax("malformed numeral"));
        }
        let text = std::str::from_utf8(&self.s[start..self.pos]).unwrap_or("");
        if !is_real {
            if let Ok(n) = text.parse::<i64>() {
                return Ok(Value::Integer(n));
            }
        }
        text.parse::<f64>()
            .map(Value::Real)
            .map_err(|_| Error::syntax("malformed numeral"))
    }

    fn operator(&mut self) -> Result<Op> {
        self.skip_ws();
        let next = self.s.get(self.pos + 1).copied();
        let (op, len) = match self.peek() {
            Some(b'=') => (Op::Eq, 1),
            Some(b'!') if next == Some(b'=') => (Op::Ne, 2),
            Some(b'<') if next == Some(b'=') => (Op::Le, 2),
            Some(b'<') => (Op::Lt, 1),
            Some(b'>') if next == Some(b'=') => (Op::Ge, 2),
            Some(b'>') => (Op::Gt, 1),
            Some(b) if is_word_byte(b) => {
                if self.word().eq_ignore_ascii_case("IS") {
                    return Ok(if self.try_kw("NOT") { Op::IsNot } else { Op::Is });
                }
                return Err(Error::syntax("unknown operator"));
            }
            _ => return Err(Error::syntax("unknown operator")),
        };
        self.pos += len;
        Ok(op)
    }

    fn condition(&mut self) -> Result<Condition> {
        let column = self.ident()?;
        let op = self.operator()?;
        let literal = self.literal()?;
        Ok(Condition { column, op, literal })
    }

    fn select(&mut self) -> Result<Select> {
        self.skip_ws();
        let columns = if self.peek() == Some(b'*') {
            self.pos += 1;
            Columns::All
        } else {
            let mut names = vec![self.ident()?];
            loop {
                self.skip_ws();
                if self.peek() == Some(b',') {
                    self.pos += 1;
                    names.push(self.ident()?);
                } else {
                    break;
                }
            }
            Columns::Named(names)
        };
        self.expect_kw("FROM")?;
        let table = self.ident()?;
        let mut conditions = Vec::new();
        if self.try_kw("WHERE") {
            loop {
                conditions.push(self.condition()?);
                if !self.try_kw("AND") {
                    break;
                }
            }
        }
        let mut order_by = None;
        if self.try_kw("ORDER") {
            self.expect_kw("BY")?;
            let col = self.ident()?;
            let desc = if self.try_kw("DESC") {
                true
            } else {
                self.try_kw("ASC");
                false
            };
            order_by = Some((col, desc));
        }
        let mut limit = None;
        if self.try_kw("LIMIT") {
            self.skip_ws();
            let start = self.pos;
            if self.digits() == 0 || self.peek().is_some_and(is_word_byte) {
                return Err(Error::syntax("malformed LIMIT"));
            }
            let text = std::str::from_utf8(&self.s[start..self.pos]).unwrap_or("0");
            limit = Some(text.parse::<u64>().unwrap_or(u64::MAX));
        }
        self.expect_end()?;
        Ok(Select { columns, table, conditions, order_by, limit })
    }
}

/// Parse one query line.
pub fn parse(line: &str) -> Result<Query> {
    if let Some(rest) = line.strip_prefix('.') {
        return parse_dot_command(rest);
    }
    let mut p = Parser { s: line.as_bytes(), pos: 0 };
    p.skip_ws();
    let cmd = p.word().to_ascii_uppercase();
    match cmd.as_str() {
        "SELECT" => p.select().map(Query::Select),
        "COUNT" => {
            let table = p.ident()?;
            p.expect_end()?;
            Ok(Query::Count(table))
        }
        "INDEX" => {
            let name = p.ident()?;
            let literal = p.literal()?;
            p.expect_end()?;
            Ok(Query::Index { name, literal })
        }
        _ => Err(Error::syntax("unknown command")),
    }
}

fn parse_dot_command(rest: &str) -> Result<Query> {
    if rest == "tables" {
        return Ok(Query::Tables);
    }
    if let Some(arg) = rest.strip_prefix("schema ") {
        let b = arg.as_bytes();
        if is_ident(arg) && b.iter().all(|&c| is_word_byte(c)) {
            return Ok(Query::Schema(arg.to_string()));
        }
    }
    Err(Error::syntax("unknown dot command"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sel(line: &str) -> Select {
        match parse(line).unwrap() {
            Query::Select(s) => s,
            q => panic!("not a select: {q:?}"),
        }
    }

    fn bad(line: &str) {
        assert!(parse(line).is_err(), "should be an error: {line:?}");
    }

    #[test]
    fn dot_commands() {
        assert_eq!(parse(".tables").unwrap(), Query::Tables);
        assert_eq!(parse(".schema t_1").unwrap(), Query::Schema("t_1".into()));
        for l in [".TABLES", ".SCHEMA t", ".schema", ".schema 9bad", ".schema people;", ".schema a b", ".tables x", ".foo"] {
            bad(l);
        }
    }

    #[test]
    fn count_and_index() {
        assert_eq!(parse("count  t").unwrap(), Query::Count("t".into()));
        bad("COUNT");
        bad("COUNT t x");
        bad("COUNTt");
        assert_eq!(
            parse("INDEX ix 'a''b'").unwrap(),
            Query::Index { name: "ix".into(), literal: Value::Text("a'b".into()) }
        );
        assert_eq!(
            parse("INDEX ix'q'").unwrap(),
            Query::Index { name: "ix".into(), literal: Value::Text("q".into()) }
        );
        bad("INDEX ix");
        bad("INDEX ix 1 2");
    }

    #[test]
    fn select_forms() {
        let s = sel("SELECT*FROM t");
        assert_eq!(s.columns, Columns::All);
        let s = sel("select  a ,b\t,c  from t where a>=1 AND b IS NOT NULL and c!='x' order by a desc limit 5");
        assert_eq!(s.columns, Columns::Named(vec!["a".into(), "b".into(), "c".into()]));
        assert_eq!(s.conditions.len(), 3);
        assert_eq!(s.conditions[0].op, Op::Ge);
        assert_eq!(s.conditions[1].op, Op::IsNot);
        assert_eq!(s.conditions[2].op, Op::Ne);
        assert_eq!(s.order_by, Some(("a".into(), true)));
        assert_eq!(s.limit, Some(5));
        let s = sel("SELECT a FROM t WHERE a<1 AND a<=2 AND a>3 AND a=4 AND a IS 5 ORDER BY a ASC");
        assert_eq!(s.order_by, Some(("a".into(), false)));
        assert_eq!(s.conditions[4].op, Op::Is);
    }

    #[test]
    fn select_errors() {
        for l in [
            "SELECTa FROM t",
            "SELECT * FROM",
            "SELECT * t",
            "SELECT a, FROM t",
            "SELECT * FROM t WHERE",
            "SELECT * FROM t WHERE a == 1",
            "SELECT * FROM t WHERE a <> 1",
            "SELECT * FROM t WHERE a = .5",
            "SELECT * FROM t WHERE a = 1e",
            "SELECT * FROM t WHERE a = 1abc",
            "SELECT * FROM t WHERE a = 'x",
            "SELECT * FROM t WHERE a = x'abc'",
            "SELECT * FROM t WHERE a = x'zz'",
            "SELECT * FROM t WHERE a IS NOTNULL",
            "SELECT * FROM t WHERE a < = 1",
            "SELECT * FROM t WHERE a = 1 AND",
            "SELECT * FROM t ORDERBY a",
            "SELECT * FROM t ORDER BY a ASC DESC",
            "SELECT * FROM t ORDER BY a LIMIT -1",
            "SELECT * FROM t LIMIT3",
            "SELECT * FROM t LIMIT 3 x",
            "SELECT * FROM t;",
            "SELECT * FROM t LIMIT 1 ORDER BY a",
            "SELECT * FROM 9t",
        ] {
            bad(l);
        }
    }

    #[test]
    fn literals() {
        let lit = |l: &str| sel(&format!("SELECT * FROM t WHERE a = {l}")).conditions[0].literal.clone();
        assert_eq!(lit("+7"), Value::Integer(7));
        assert_eq!(lit("-9223372036854775808"), Value::Integer(i64::MIN));
        assert_eq!(lit("1."), Value::Real(1.0));
        assert_eq!(lit("-2.5e-3"), Value::Real(-0.0025));
        assert_eq!(lit("1E2"), Value::Real(100.0));
        assert_eq!(lit("''''"), Value::Text("'".into()));
        assert_eq!(lit("x''"), Value::Blob(vec![]));
        assert_eq!(lit("X'0aFf'"), Value::Blob(vec![0x0a, 0xff]));
        assert_eq!(lit("nUlL"), Value::Null);
        assert_eq!(lit("'é\t'"), Value::Text("é\t".into()));
    }
}
