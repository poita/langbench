//! Recursive-descent parser: tokens to [`Statement`].

use crate::ast::*;
use crate::error::{Error, Result};
use crate::lexer::{Keyword, Token};

/// Parses one statement (the tokens between two `;`).
///
/// # Errors
/// [`Error::Syntax`] if the tokens do not form exactly one valid statement.
pub fn parse_statement(tokens: &[Token]) -> Result<Statement> {
    let mut p = Parser { toks: tokens, pos: 0 };
    let stmt = p.statement()?;
    if p.pos != tokens.len() {
        return Err(p.unexpected());
    }
    Ok(stmt)
}

struct Parser<'a> {
    toks: &'a [Token],
    pos: usize,
}

type Kw = Keyword;

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a Token> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, n: usize) -> Option<&'a Token> {
        self.toks.get(self.pos + n)
    }

    fn unexpected(&self) -> Error {
        match self.peek() {
            Some(t) => Error::syntax(format!("unexpected token {t:?}")),
            None => Error::syntax("unexpected end of statement"),
        }
    }

    fn eat(&mut self, t: &Token) -> bool {
        if self.peek() == Some(t) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn eat_kw(&mut self, k: Kw) -> bool {
        self.eat(&Token::Keyword(k))
    }

    fn expect(&mut self, t: Token) -> Result<()> {
        if self.eat(&t) {
            Ok(())
        } else {
            Err(self.unexpected())
        }
    }

    fn expect_kw(&mut self, k: Kw) -> Result<()> {
        self.expect(Token::Keyword(k))
    }

    fn ident(&mut self) -> Result<String> {
        match self.peek() {
            Some(Token::Ident(s)) => {
                self.pos += 1;
                Ok(s.clone())
            }
            _ => Err(self.unexpected()),
        }
    }

    fn integer(&mut self) -> Result<u64> {
        match self.peek() {
            Some(Token::Integer(n)) => {
                self.pos += 1;
                Ok(*n)
            }
            _ => Err(self.unexpected()),
        }
    }

    // ---- statements ----

    fn statement(&mut self) -> Result<Statement> {
        match self.peek() {
            Some(Token::Keyword(Kw::Create)) => self.create_table(),
            Some(Token::Keyword(Kw::Insert)) => self.insert(),
            Some(Token::Keyword(Kw::Delete)) => self.delete(),
            Some(Token::Keyword(Kw::Update)) => self.update(),
            Some(Token::Keyword(Kw::Select)) => self.select().map(|s| Statement::Select(Box::new(s))),
            _ => Err(self.unexpected()),
        }
    }

    fn create_table(&mut self) -> Result<Statement> {
        self.expect_kw(Kw::Create)?;
        self.expect_kw(Kw::Table)?;
        let name = self.ident()?;
        self.expect(Token::LParen)?;
        let mut columns = Vec::new();
        loop {
            let col = self.ident()?;
            let ty = if self.eat_kw(Kw::Integer) {
                ColumnType::Integer
            } else if self.eat_kw(Kw::Text) {
                ColumnType::Text
            } else {
                return Err(self.unexpected());
            };
            columns.push((col, ty));
            if !self.eat(&Token::Comma) {
                break;
            }
        }
        self.expect(Token::RParen)?;
        Ok(Statement::CreateTable { name, columns })
    }

    fn insert(&mut self) -> Result<Statement> {
        self.expect_kw(Kw::Insert)?;
        self.expect_kw(Kw::Into)?;
        let table = self.ident()?;
        self.expect_kw(Kw::Values)?;
        let mut rows = Vec::new();
        loop {
            self.expect(Token::LParen)?;
            let mut row = vec![self.expr()?];
            while self.eat(&Token::Comma) {
                row.push(self.expr()?);
            }
            self.expect(Token::RParen)?;
            rows.push(row);
            if !self.eat(&Token::Comma) {
                break;
            }
        }
        Ok(Statement::Insert { table, rows })
    }

    fn opt_where(&mut self) -> Result<Option<Expr>> {
        if self.eat_kw(Kw::Where) {
            Ok(Some(self.expr()?))
        } else {
            Ok(None)
        }
    }

    fn delete(&mut self) -> Result<Statement> {
        self.expect_kw(Kw::Delete)?;
        self.expect_kw(Kw::From)?;
        let table = self.ident()?;
        let filter = self.opt_where()?;
        Ok(Statement::Delete { table, filter })
    }

    fn update(&mut self) -> Result<Statement> {
        self.expect_kw(Kw::Update)?;
        let table = self.ident()?;
        self.expect_kw(Kw::Set)?;
        let mut assignments = Vec::new();
        loop {
            let col = self.ident()?;
            self.expect(Token::Eq)?;
            assignments.push((col, self.expr()?));
            if !self.eat(&Token::Comma) {
                break;
            }
        }
        let filter = self.opt_where()?;
        Ok(Statement::Update { table, assignments, filter })
    }

    fn select(&mut self) -> Result<Select> {
        self.expect_kw(Kw::Select)?;
        let mut items = vec![self.select_item()?];
        while self.eat(&Token::Comma) {
            items.push(self.select_item()?);
        }
        let from = if self.eat_kw(Kw::From) {
            Some(self.parse_from()?)
        } else {
            None
        };
        let filter = self.opt_where()?;
        let mut group_by = Vec::new();
        let mut having = None;
        if self.eat_kw(Kw::Group) {
            self.expect_kw(Kw::By)?;
            group_by.push(self.column_ref()?);
            while self.eat(&Token::Comma) {
                group_by.push(self.column_ref()?);
            }
            if self.eat_kw(Kw::Having) {
                having = Some(self.expr()?);
            }
        }
        let mut order_by = Vec::new();
        if self.eat_kw(Kw::Order) {
            self.expect_kw(Kw::By)?;
            loop {
                let expr = self.expr()?;
                let desc = if self.eat_kw(Kw::Desc) {
                    true
                } else {
                    self.eat_kw(Kw::Asc);
                    false
                };
                order_by.push(OrderTerm { expr, desc });
                if !self.eat(&Token::Comma) {
                    break;
                }
            }
        }
        let (mut limit, mut offset) = (None, None);
        if self.eat_kw(Kw::Limit) {
            limit = Some(self.integer()?);
            if self.eat_kw(Kw::Offset) {
                offset = Some(self.integer()?);
            }
        }
        Ok(Select { items, from, filter, group_by, having, order_by, limit, offset })
    }

    fn select_item(&mut self) -> Result<SelectItem> {
        if self.eat(&Token::Star) {
            return Ok(SelectItem::Star);
        }
        let expr = self.expr()?;
        let alias = if self.eat_kw(Kw::As) {
            Some(self.ident()?)
        } else if let Some(Token::Ident(_)) = self.peek() {
            Some(self.ident()?)
        } else {
            None
        };
        Ok(SelectItem::Expr { expr, alias })
    }

    fn table_ref(&mut self) -> Result<TableRef> {
        let name = self.ident()?;
        let alias = if self.eat_kw(Kw::As) {
            Some(self.ident()?)
        } else if let Some(Token::Ident(_)) = self.peek() {
            Some(self.ident()?)
        } else {
            None
        };
        Ok(TableRef { name, alias })
    }

    fn parse_from(&mut self) -> Result<FromClause> {
        let first = self.table_ref()?;
        if self.eat(&Token::Comma) {
            let second = self.table_ref()?;
            return Ok(FromClause { first, second: Some(second), on: None });
        }
        if self.eat_kw(Kw::Inner) {
            self.expect_kw(Kw::Join)?;
        } else if !self.eat_kw(Kw::Join) {
            return Ok(FromClause { first, second: None, on: None });
        }
        let second = self.table_ref()?;
        self.expect_kw(Kw::On)?;
        let on = self.expr()?;
        Ok(FromClause { first, second: Some(second), on: Some(on) })
    }

    fn column_ref(&mut self) -> Result<ColumnRef> {
        let first = self.ident()?;
        if self.eat(&Token::Dot) {
            let name = self.ident()?;
            Ok(ColumnRef { qualifier: Some(first), name })
        } else {
            Ok(ColumnRef { qualifier: None, name: first })
        }
    }

    // ---- expressions ----

    fn expr(&mut self) -> Result<Expr> {
        let mut lhs = self.and_expr()?;
        while self.eat_kw(Kw::Or) {
            let rhs = self.and_expr()?;
            lhs = binary(BinOp::Or, lhs, rhs);
        }
        Ok(lhs)
    }

    fn and_expr(&mut self) -> Result<Expr> {
        let mut lhs = self.not_expr()?;
        while self.eat_kw(Kw::And) {
            let rhs = self.not_expr()?;
            lhs = binary(BinOp::And, lhs, rhs);
        }
        Ok(lhs)
    }

    fn not_expr(&mut self) -> Result<Expr> {
        if self.eat_kw(Kw::Not) {
            Ok(Expr::Not(Box::new(self.not_expr()?)))
        } else {
            self.eq_expr()
        }
    }

    fn eq_expr(&mut self) -> Result<Expr> {
        let mut lhs = self.rel_expr()?;
        loop {
            match self.peek() {
                Some(Token::Eq) | Some(Token::Ne) => {
                    let op = if self.peek() == Some(&Token::Eq) { BinOp::Eq } else { BinOp::Ne };
                    self.pos += 1;
                    let rhs = self.rel_expr()?;
                    lhs = binary(op, lhs, rhs);
                }
                Some(Token::Keyword(Kw::Is)) => {
                    self.pos += 1;
                    let negated = self.eat_kw(Kw::Not);
                    self.expect_kw(Kw::Null)?;
                    lhs = Expr::IsNull { expr: Box::new(lhs), negated };
                }
                Some(Token::Keyword(Kw::Not))
                    if self.peek_at(1) == Some(&Token::Keyword(Kw::Like)) =>
                {
                    self.pos += 2;
                    let pattern = self.rel_expr()?;
                    lhs = Expr::Like { expr: Box::new(lhs), pattern: Box::new(pattern), negated: true };
                }
                Some(Token::Keyword(Kw::Like)) => {
                    self.pos += 1;
                    let pattern = self.rel_expr()?;
                    lhs = Expr::Like { expr: Box::new(lhs), pattern: Box::new(pattern), negated: false };
                }
                _ => return Ok(lhs),
            }
        }
    }

    fn rel_expr(&mut self) -> Result<Expr> {
        let mut lhs = self.add_expr()?;
        loop {
            let op = match self.peek() {
                Some(Token::Lt) => BinOp::Lt,
                Some(Token::Le) => BinOp::Le,
                Some(Token::Gt) => BinOp::Gt,
                Some(Token::Ge) => BinOp::Ge,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.add_expr()?;
            lhs = binary(op, lhs, rhs);
        }
    }

    fn add_expr(&mut self) -> Result<Expr> {
        let mut lhs = self.mul_expr()?;
        loop {
            let op = match self.peek() {
                Some(Token::Plus) => BinOp::Add,
                Some(Token::Minus) => BinOp::Sub,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.mul_expr()?;
            lhs = binary(op, lhs, rhs);
        }
    }

    fn mul_expr(&mut self) -> Result<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let op = match self.peek() {
                Some(Token::Star) => BinOp::Mul,
                Some(Token::Slash) => BinOp::Div,
                Some(Token::Percent) => BinOp::Rem,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.unary()?;
            lhs = binary(op, lhs, rhs);
        }
    }

    fn unary(&mut self) -> Result<Expr> {
        if self.eat(&Token::Minus) {
            Ok(Expr::Neg(Box::new(self.unary()?)))
        } else {
            self.primary()
        }
    }

    fn primary(&mut self) -> Result<Expr> {
        match self.peek() {
            Some(Token::Integer(n)) => {
                let v = i64::try_from(*n).map_err(|_| Error::syntax("integer literal out of range"))?;
                self.pos += 1;
                Ok(Expr::Int(v))
            }
            Some(Token::Str(s)) => {
                self.pos += 1;
                Ok(Expr::Str(s.clone()))
            }
            Some(Token::Keyword(Kw::Null)) => {
                self.pos += 1;
                Ok(Expr::Null)
            }
            Some(Token::LParen) => {
                self.pos += 1;
                let e = self.expr()?;
                self.expect(Token::RParen)?;
                Ok(e)
            }
            Some(Token::Ident(name)) => {
                if self.peek_at(1) == Some(&Token::LParen) {
                    let func = match name.as_str() {
                        "count" => AggFunc::Count,
                        "sum" => AggFunc::Sum,
                        "min" => AggFunc::Min,
                        "max" => AggFunc::Max,
                        "avg" => AggFunc::Avg,
                        _ => return Err(Error::syntax(format!("unknown function {name}"))),
                    };
                    self.pos += 2;
                    if func == AggFunc::Count && self.eat(&Token::Star) {
                        self.expect(Token::RParen)?;
                        return Ok(Expr::Aggregate { func, arg: None });
                    }
                    let arg = self.expr()?;
                    self.expect(Token::RParen)?;
                    Ok(Expr::Aggregate { func, arg: Some(Box::new(arg)) })
                } else {
                    Ok(Expr::Column(self.column_ref()?))
                }
            }
            _ => Err(self.unexpected()),
        }
    }
}

fn binary(op: BinOp, lhs: Expr, rhs: Expr) -> Expr {
    Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexer::tokenize;

    fn parse(s: &str) -> Result<Statement> {
        parse_statement(&tokenize(s))
    }

    fn expr(s: &str) -> Expr {
        match parse(&format!("select {s}")).unwrap() {
            Statement::Select(sel) => match sel.items.into_iter().next().unwrap() {
                SelectItem::Expr { expr, .. } => expr,
                _ => panic!(),
            },
            _ => panic!(),
        }
    }

    #[test]
    fn precedence() {
        // NOT a = 1  is  NOT (a = 1)
        assert!(matches!(expr("not a = 1"), Expr::Not(_)));
        // 1 < 2 = 1 is (1 < 2) = 1
        match expr("1 < 2 = 1") {
            Expr::Binary { op: BinOp::Eq, lhs, .. } => {
                assert!(matches!(*lhs, Expr::Binary { op: BinOp::Lt, .. }))
            }
            e => panic!("{e:?}"),
        }
        // -5 % 3 is (-5) % 3
        match expr("-5 % 3") {
            Expr::Binary { op: BinOp::Rem, lhs, .. } => assert!(matches!(*lhs, Expr::Neg(_))),
            e => panic!("{e:?}"),
        }
    }

    #[test]
    fn count_as_column_and_function() {
        assert!(matches!(expr("count"), Expr::Column(_)));
        assert!(matches!(expr("count (*)"), Expr::Aggregate { .. }));
        assert!(parse("select foo(1)").is_err());
        assert!(parse("select sum(*)").is_err());
    }

    #[test]
    fn rejects_unsupported() {
        for s in [
            "drop table t",
            "select * from a left join b on 1",
            "select * from a, b, c",
            "select 1 in (1)",
            "select 1 between 1 and 2",
            "select distinct 1",
            "select 1 || 2",
            "insert into t (a) values (1)",
            "create table t (a real)",
            "create table t (a)",
            "create table t ()",
            "select 1 limit -1",
            "select 1 offset 1",
            "select a + 1 from t group by a + 1",
            "create table t (text text)",
            "select a as left from t",
            "select * x from t",
            "select 1.5",
        ] {
            assert!(parse(s).is_err(), "{s}");
        }
    }

    #[test]
    fn accepts_forms() {
        for s in [
            "select * from t e",
            "select a x, b as y from t as e inner join u on e.a = u.a where a is not null",
            "select a from t where a not like 'x%' order by 1 desc, a limit 2 offset 1",
            "select a from t group by a, t.b having count(*) > 1",
            "update t set a = b, b = a where t.a = 1",
            "insert into t values (1, 'a'), (2, 'b')",
        ] {
            assert!(parse(s).is_ok(), "{s}");
        }
    }
}
