//! A small tokenizer and parser for `CREATE TABLE` and `CREATE INDEX`
//! statements (SPEC Part 2). Only what the reader needs is extracted: column
//! names, declared types, the rowid alias, and index column lists.

use crate::error::{Error, Result};

#[derive(Debug, Clone, PartialEq)]
enum Token {
    /// An unquoted run of word characters (keywords, identifiers, numbers).
    Word(String),
    /// A `"..."`, `` `...` `` or `[...]` quoted name (quotes removed).
    Quoted(String),
    /// One of `( ) , . ;`.
    Punct(char),
    /// Anything else: string literals, operators, ...
    Other(String),
}

impl Token {
    fn text(&self) -> String {
        match self {
            Token::Word(s) | Token::Quoted(s) | Token::Other(s) => s.clone(),
            Token::Punct(c) => c.to_string(),
        }
    }

    fn is_kw(&self, kw: &str) -> bool {
        matches!(self, Token::Word(w) if w.eq_ignore_ascii_case(kw))
    }

    fn is_punct(&self, c: char) -> bool {
        matches!(self, Token::Punct(p) if *p == c)
    }

    /// Name text if this token can be an identifier.
    fn name(&self) -> Option<String> {
        match self {
            Token::Word(s) | Token::Quoted(s) => Some(s.clone()),
            _ => None,
        }
    }
}

fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$' || !c.is_ascii()
}

fn lex(sql: &str) -> Vec<Token> {
    let c: Vec<char> = sql.chars().collect();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        if ch.is_whitespace() {
            i += 1;
        } else if ch == '-' && c.get(i + 1) == Some(&'-') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            i += 2;
            while i < c.len() && !(c[i] == '*' && c.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i = (i + 2).min(c.len());
        } else if ch == '"' || ch == '`' || ch == '\'' {
            let mut s = String::new();
            i += 1;
            while i < c.len() {
                if c[i] == ch {
                    if c.get(i + 1) == Some(&ch) {
                        s.push(ch);
                        i += 2;
                        continue;
                    }
                    break;
                }
                s.push(c[i]);
                i += 1;
            }
            i += 1;
            toks.push(if ch == '\'' { Token::Other(s) } else { Token::Quoted(s) });
        } else if ch == '[' {
            let mut s = String::new();
            i += 1;
            while i < c.len() && c[i] != ']' {
                s.push(c[i]);
                i += 1;
            }
            i += 1;
            toks.push(Token::Quoted(s));
        } else if is_word_char(ch) {
            let start = i;
            while i < c.len() && is_word_char(c[i]) {
                i += 1;
            }
            toks.push(Token::Word(c[start..i].iter().collect()));
        } else if "(),.;".contains(ch) {
            toks.push(Token::Punct(ch));
            i += 1;
        } else {
            toks.push(Token::Other(ch.to_string()));
            i += 1;
        }
    }
    toks
}

/// One column of a parsed `CREATE TABLE`.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnDef {
    /// Column name as written (quotes removed).
    pub name: String,
    /// Declared type, tokens joined by single spaces; empty if none.
    pub declared_type: String,
}

/// A parsed `CREATE TABLE` statement.
#[derive(Debug, Clone, PartialEq)]
pub struct TableDef {
    /// Table name as written.
    pub name: String,
    /// Columns in declaration order.
    pub columns: Vec<ColumnDef>,
    /// Index of the column that aliases the rowid, if any (SPEC §2.2).
    pub rowid_alias: Option<usize>,
}

/// A parsed `CREATE INDEX` statement.
#[derive(Debug, Clone, PartialEq)]
pub struct IndexDef {
    /// Index name as written.
    pub name: String,
    /// Name of the indexed table.
    pub table: String,
    /// Indexed column names, in order.
    pub columns: Vec<String>,
}

struct Cursor {
    toks: Vec<Token>,
    pos: usize,
}

impl Cursor {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.pos)
    }
    fn eat_kw(&mut self, kw: &str) -> bool {
        if self.peek().is_some_and(|t| t.is_kw(kw)) {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn expect_kw(&mut self, kw: &str) -> Result<()> {
        if self.eat_kw(kw) {
            Ok(())
        } else {
            Err(Error::corrupt(format!("expected {kw} in schema SQL")))
        }
    }
    fn expect_punct(&mut self, c: char) -> Result<()> {
        if self.peek().is_some_and(|t| t.is_punct(c)) {
            self.pos += 1;
            Ok(())
        } else {
            Err(Error::corrupt(format!("expected '{c}' in schema SQL")))
        }
    }
    fn name(&mut self) -> Result<String> {
        match self.peek().and_then(Token::name) {
            Some(n) => {
                self.pos += 1;
                Ok(n)
            }
            None => Err(Error::corrupt("expected a name in schema SQL")),
        }
    }
    /// `[schema.]name`, returning the final component.
    fn qualified_name(&mut self) -> Result<String> {
        let mut n = self.name()?;
        if self.peek().is_some_and(|t| t.is_punct('.')) {
            self.pos += 1;
            n = self.name()?;
        }
        Ok(n)
    }
    /// Collect the tokens up to the `)` matching an already consumed `(`,
    /// split at commas of nesting depth 0.
    fn parenthesised_items(&mut self) -> Result<Vec<Vec<Token>>> {
        let mut items = vec![Vec::new()];
        let mut depth = 0usize;
        while let Some(t) = self.peek().cloned() {
            self.pos += 1;
            match &t {
                Token::Punct('(') => depth += 1,
                Token::Punct(')') => {
                    if depth == 0 {
                        return Ok(items);
                    }
                    depth -= 1;
                }
                Token::Punct(',') if depth == 0 => {
                    items.push(Vec::new());
                    continue;
                }
                _ => {}
            }
            items.last_mut().expect("non-empty").push(t);
        }
        Err(Error::corrupt("unbalanced parentheses in schema SQL"))
    }
}

const TABLE_CONSTRAINT_STARTS: [&str; 5] = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"];
const TYPE_TERMINATORS: [&str; 12] = [
    "CONSTRAINT",
    "PRIMARY",
    "NOT",
    "NULL",
    "UNIQUE",
    "CHECK",
    "DEFAULT",
    "COLLATE",
    "REFERENCES",
    "GENERATED",
    "AS",
    "AUTOINCREMENT",
];

/// Parse a `CREATE TABLE` statement.
pub fn parse_create_table(sql: &str) -> Result<TableDef> {
    let mut cur = Cursor { toks: lex(sql), pos: 0 };
    cur.expect_kw("CREATE")?;
    let _ = cur.eat_kw("TEMP") || cur.eat_kw("TEMPORARY");
    cur.expect_kw("TABLE")?;
    if cur.eat_kw("IF") {
        cur.expect_kw("NOT")?;
        cur.expect_kw("EXISTS")?;
    }
    let name = cur.qualified_name()?;
    cur.expect_punct('(')?;
    let items = cur.parenthesised_items()?;

    let mut columns: Vec<ColumnDef> = Vec::new();
    let mut column_pk: Option<usize> = None;
    let mut table_pk: Option<String> = None;

    for item in &items {
        let Some(first) = item.first() else { continue };
        let is_constraint = TABLE_CONSTRAINT_STARTS.iter().any(|k| first.is_kw(k));
        if is_constraint {
            if table_pk.is_none() {
                table_pk = table_primary_key(item);
            }
            continue;
        }
        let col_name = first
            .name()
            .ok_or_else(|| Error::corrupt("bad column definition"))?;
        let rest = &item[1..];
        let type_len = rest
            .iter()
            .position(|t| TYPE_TERMINATORS.iter().any(|k| t.is_kw(k)))
            .unwrap_or(rest.len());
        let declared_type = rest[..type_len]
            .iter()
            .map(Token::text)
            .collect::<Vec<_>>()
            .join(" ");
        if column_pk.is_none() && is_integer_type(&rest[..type_len]) {
            // Column-level PRIMARY KEY that is not followed by DESC.
            let cons = &rest[type_len..];
            for w in 0..cons.len().saturating_sub(1) {
                if cons[w].is_kw("PRIMARY") && cons[w + 1].is_kw("KEY") {
                    if !cons.get(w + 2).is_some_and(|t| t.is_kw("DESC")) {
                        column_pk = Some(columns.len());
                    }
                    break;
                }
            }
        }
        columns.push(ColumnDef { name: col_name, declared_type });
    }

    let mut rowid_alias = column_pk;
    if rowid_alias.is_none() {
        if let Some(pk) = table_pk {
            rowid_alias = columns.iter().position(|c| {
                c.name.eq_ignore_ascii_case(&pk) && c.declared_type.eq_ignore_ascii_case("INTEGER")
            });
        }
    }
    Ok(TableDef { name, columns, rowid_alias })
}

fn is_integer_type(tokens: &[Token]) -> bool {
    matches!(tokens, [t] if t.is_kw("INTEGER"))
}

/// For a table constraint `[CONSTRAINT n] PRIMARY KEY (<one column>)`, the
/// name of that column.
fn table_primary_key(item: &[Token]) -> Option<String> {
    let mut depth = 0usize;
    let mut i = 0;
    while i < item.len() {
        match &item[i] {
            Token::Punct('(') => depth += 1,
            Token::Punct(')') => depth = depth.saturating_sub(1),
            t if depth == 0 && t.is_kw("PRIMARY") => {
                if item.get(i + 1).is_some_and(|t| t.is_kw("KEY"))
                    && item.get(i + 2).is_some_and(|t| t.is_punct('('))
                {
                    let mut cur = Cursor { toks: item[i + 3..].to_vec(), pos: 0 };
                    let elems = cur.parenthesised_items().ok()?;
                    if elems.len() == 1 {
                        return elems[0].first().and_then(Token::name);
                    }
                }
                return None;
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Parse a `CREATE INDEX` statement.
pub fn parse_create_index(sql: &str) -> Result<IndexDef> {
    let mut cur = Cursor { toks: lex(sql), pos: 0 };
    cur.expect_kw("CREATE")?;
    let _ = cur.eat_kw("UNIQUE");
    cur.expect_kw("INDEX")?;
    if cur.eat_kw("IF") {
        cur.expect_kw("NOT")?;
        cur.expect_kw("EXISTS")?;
    }
    let name = cur.qualified_name()?;
    cur.expect_kw("ON")?;
    let table = cur.qualified_name()?;
    cur.expect_punct('(')?;
    let items = cur.parenthesised_items()?;
    let mut columns = Vec::new();
    for item in items {
        let n = item
            .first()
            .and_then(Token::name)
            .ok_or_else(|| Error::corrupt("bad index column"))?;
        columns.push(n);
    }
    Ok(IndexDef { name, table, columns })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alias(sql: &str) -> Option<usize> {
        parse_create_table(sql).unwrap().rowid_alias
    }

    #[test]
    fn basic_columns_and_types() {
        let t = parse_create_table(
            "CREATE TABLE people(\n id INTEGER PRIMARY KEY,\n name TEXT NOT NULL,\n price NUMERIC(10,2) DEFAULT (1,2), x)",
        )
        .unwrap();
        assert_eq!(t.name, "people");
        let cols: Vec<_> = t
            .columns
            .iter()
            .map(|c| (c.name.as_str(), c.declared_type.as_str()))
            .collect();
        assert_eq!(
            cols,
            vec![
                ("id", "INTEGER"),
                ("name", "TEXT"),
                ("price", "NUMERIC ( 10 , 2 )"),
                ("x", "")
            ]
        );
        assert_eq!(t.rowid_alias, Some(0));
    }

    #[test]
    fn rowid_alias_shapes() {
        assert_eq!(alias("CREATE TABLE t(x INTEGER PRIMARY KEY DESC)"), None);
        assert_eq!(alias("CREATE TABLE t(x INTEGER, PRIMARY KEY(x DESC))"), Some(0));
        assert_eq!(alias("CREATE TABLE t(code INT PRIMARY KEY)"), None);
        assert_eq!(alias("CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))"), None);
        assert_eq!(
            alias("CREATE TABLE t([a] INTEGER NOT NULL, CONSTRAINT [pk] PRIMARY KEY ([A]))"),
            Some(0)
        );
        assert_eq!(alias("CREATE TABLE t(a INTEGER PRIMARY KEY AUTOINCREMENT)"), Some(0));
        assert_eq!(alias("CREATE TABLE t(a INTEGER(5) PRIMARY KEY)"), None);
        assert_eq!(alias("CREATE TABLE t(a TEXT, b INTEGER PRIMARY KEY)"), Some(1));
        assert_eq!(alias("CREATE TABLE t(a INTEGER)"), None);
    }

    #[test]
    fn quoting_comments_and_options() {
        let t = parse_create_table(
            "CREATE TEMP TABLE IF NOT EXISTS main.\"we\"\"ird\" ( -- c\n `a b` TEXT, /* x, y */ [c d] INT CHECK (c > 1), \"e\" )",
        )
        .unwrap();
        assert_eq!(t.name, "we\"ird");
        let names: Vec<_> = t.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["a b", "c d", "e"]);
        assert_eq!(t.columns[1].declared_type, "INT");
    }

    #[test]
    fn string_defaults_do_not_split() {
        let t = parse_create_table("CREATE TABLE t(a TEXT DEFAULT 'x,)', b INT)").unwrap();
        assert_eq!(t.columns.len(), 2);
    }

    #[test]
    fn index_parsing() {
        let i = parse_create_index(
            "CREATE UNIQUE INDEX IF NOT EXISTS main.ix ON \"t\"(a COLLATE BINARY DESC, [b])",
        )
        .unwrap();
        assert_eq!(i.name, "ix");
        assert_eq!(i.table, "t");
        assert_eq!(i.columns, vec!["a", "b"]);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_create_table("CREATE VIEW v AS SELECT 1").is_err());
        assert!(parse_create_table("CREATE TABLE t(a").is_err());
        assert!(parse_create_index("CREATE INDEX i ON t").is_err());
    }
}
