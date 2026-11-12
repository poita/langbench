//! The recursive-descent parser (pass 2).

use crate::ast::*;
use crate::diag::{err, ErrorKind, Pos, Res};
use crate::lexer::{Kw, Token, Tok, P};
use std::rc::Rc;

/// Parses one module's tokens into a syntax tree.
///
/// `eof_pos` is the position reported when the input ends too early.
///
/// # Errors
/// A `parse` diagnostic at the token that could not be accepted.
pub fn parse_module(tokens: Vec<Token>, eof_pos: Pos) -> Res<Module> {
    let mut p = Parser { toks: tokens, i: 0, eof_pos, split_gt: false, targ_depth: 0 };
    let mut items = Vec::new();
    while p.i < p.toks.len() {
        items.push(p.parse_item()?);
    }
    Ok(Module { items })
}

struct Parser {
    toks: Vec<Token>,
    i: usize,
    eof_pos: Pos,
    split_gt: bool,
    targ_depth: u32,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.i).map(|t| &t.tok)
    }
    fn peek_at(&self, k: usize) -> Option<&Tok> {
        self.toks.get(self.i + k).map(|t| &t.tok)
    }
    fn pos(&self) -> Pos {
        self.toks.get(self.i).map_or(self.eof_pos, |t| t.pos)
    }
    fn fail<T>(&self) -> Res<T> {
        err(ErrorKind::Parse, self.pos())
    }
    fn advance(&mut self) {
        self.i += 1;
    }
    fn at_p(&self, p: P) -> bool {
        matches!(self.peek(), Some(Tok::P(q)) if *q == p)
    }
    fn at_kw(&self, k: Kw) -> bool {
        matches!(self.peek(), Some(Tok::Kw(q)) if *q == k)
    }
    fn eat_p(&mut self, p: P) -> bool {
        if self.at_p(p) {
            self.advance();
            true
        } else {
            false
        }
    }
    fn eat_kw(&mut self, k: Kw) -> bool {
        if self.at_kw(k) {
            self.advance();
            true
        } else {
            false
        }
    }
    fn expect_p(&mut self, p: P) -> Res<Pos> {
        let pos = self.pos();
        if self.eat_p(p) {
            Ok(pos)
        } else {
            self.fail()
        }
    }
    fn expect_kw(&mut self, k: Kw) -> Res<Pos> {
        let pos = self.pos();
        if self.eat_kw(k) {
            Ok(pos)
        } else {
            self.fail()
        }
    }
    fn ident(&mut self) -> Res<Ident> {
        let pos = self.pos();
        match self.peek() {
            Some(Tok::Ident(s)) => {
                let name = s.clone();
                self.advance();
                Ok(Ident { name, pos })
            }
            _ => self.fail(),
        }
    }
    fn at_ident(&self) -> bool {
        matches!(self.peek(), Some(Tok::Ident(_)))
    }

    // ---------------------------------------------------------------- items

    fn parse_item(&mut self) -> Res<Item> {
        match self.peek() {
            Some(Tok::Kw(Kw::Use)) => {
                let pos = self.pos();
                self.advance();
                let module = self.ident()?;
                let alias = if self.eat_kw(Kw::As) { Some(self.ident()?) } else { None };
                self.expect_p(P::Semi)?;
                Ok(Item::Use(UseDecl { pos, module, alias }))
            }
            Some(Tok::Kw(Kw::Impl)) => self.parse_impl(),
            Some(Tok::Kw(Kw::Pub)) => {
                self.advance();
                self.parse_decl(true)
            }
            _ => self.parse_decl(false),
        }
    }

    fn parse_decl(&mut self, is_pub: bool) -> Res<Item> {
        let pos = self.pos();
        match self.peek() {
            Some(Tok::Kw(Kw::Fn)) => {
                self.advance();
                let name = self.ident()?;
                let generics = self.parse_generics(true)?;
                self.expect_p(P::LParen)?;
                let params = self.parse_params()?;
                self.expect_p(P::RParen)?;
                let ret = self.parse_ret()?;
                let body = self.parse_block()?;
                Ok(Item::Fn(Rc::new(FnDecl { pos, is_pub, name, generics, params, ret, body })))
            }
            Some(Tok::Kw(Kw::Struct)) => {
                self.advance();
                let name = self.ident()?;
                let generics = self.parse_generics(false)?;
                self.expect_p(P::LBrace)?;
                let mut fields = Vec::new();
                while !self.at_p(P::RBrace) {
                    let fname = self.ident()?;
                    self.expect_p(P::Colon)?;
                    let ty = self.parse_type()?;
                    fields.push(Param { name: fname, ty });
                    if !self.eat_p(P::Comma) {
                        break;
                    }
                }
                self.expect_p(P::RBrace)?;
                Ok(Item::Struct(Rc::new(StructDecl { pos, is_pub, name, generics, fields })))
            }
            Some(Tok::Kw(Kw::Enum)) => {
                self.advance();
                let name = self.ident()?;
                let generics = self.parse_generics(false)?;
                self.expect_p(P::LBrace)?;
                let mut variants = Vec::new();
                while !self.at_p(P::RBrace) {
                    let vname = self.ident()?;
                    let mut payload = Vec::new();
                    if self.eat_p(P::LParen) {
                        payload.push(self.parse_type()?);
                        while self.eat_p(P::Comma) {
                            if self.at_p(P::RParen) {
                                break;
                            }
                            payload.push(self.parse_type()?);
                        }
                        self.expect_p(P::RParen)?;
                    }
                    variants.push(Variant { name: vname, payload });
                    if !self.eat_p(P::Comma) {
                        break;
                    }
                }
                self.expect_p(P::RBrace)?;
                Ok(Item::Enum(Rc::new(EnumDecl { pos, is_pub, name, generics, variants })))
            }
            Some(Tok::Kw(Kw::Trait)) => {
                self.advance();
                let name = self.ident()?;
                self.expect_p(P::LBrace)?;
                let mut methods = Vec::new();
                while !self.at_p(P::RBrace) {
                    methods.push(self.parse_method(true)?);
                }
                self.expect_p(P::RBrace)?;
                Ok(Item::Trait(Rc::new(TraitDecl { pos, is_pub, name, methods })))
            }
            _ => self.fail(),
        }
    }

    fn parse_impl(&mut self) -> Res<Item> {
        let pos = self.expect_kw(Kw::Impl)?;
        let generics = self.parse_generics(true)?;
        let trait_ref = self.parse_path()?;
        self.expect_kw(Kw::For)?;
        let head = self.parse_type()?;
        self.expect_p(P::LBrace)?;
        let mut methods = Vec::new();
        while !self.at_p(P::RBrace) {
            methods.push(self.parse_method(false)?);
        }
        self.expect_p(P::RBrace)?;
        Ok(Item::Impl(Rc::new(ImplDecl { pos, generics, trait_ref, head, methods })))
    }

    fn parse_method(&mut self, in_trait: bool) -> Res<MethodDecl> {
        let pos = self.expect_kw(Kw::Fn)?;
        let name = self.ident()?;
        self.expect_p(P::LParen)?;
        self.expect_kw(Kw::SelfKw)?;
        let mut params = Vec::new();
        if self.eat_p(P::Comma) {
            params = self.parse_params_nonempty()?;
        }
        self.expect_p(P::RParen)?;
        let ret = self.parse_ret()?;
        let body = if in_trait && self.eat_p(P::Semi) { None } else { Some(self.parse_block()?) };
        Ok(MethodDecl { pos, name, params, ret, body })
    }

    fn parse_ret(&mut self) -> Res<Option<TypeExpr>> {
        if self.eat_p(P::Arrow) {
            Ok(Some(self.parse_type()?))
        } else {
            Ok(None)
        }
    }

    fn parse_params(&mut self) -> Res<Vec<Param>> {
        if self.at_p(P::RParen) {
            return Ok(Vec::new());
        }
        self.parse_params_nonempty()
    }

    fn parse_params_nonempty(&mut self) -> Res<Vec<Param>> {
        let mut out = Vec::new();
        loop {
            let name = self.ident()?;
            self.expect_p(P::Colon)?;
            let ty = self.parse_type()?;
            out.push(Param { name, ty });
            if !self.eat_p(P::Comma) || self.at_p(P::RParen) {
                break;
            }
        }
        Ok(out)
    }

    fn parse_generics(&mut self, allow_bounds: bool) -> Res<Vec<GenParam>> {
        let mut out = Vec::new();
        if !self.eat_p(P::Lt) {
            return Ok(out);
        }
        loop {
            let name = self.ident()?;
            let mut bounds = Vec::new();
            if allow_bounds && self.eat_p(P::Colon) {
                bounds.push(self.parse_path()?);
                while self.eat_p(P::Plus) {
                    bounds.push(self.parse_path()?);
                }
            }
            out.push(GenParam { name, bounds });
            if !self.eat_p(P::Comma) || self.at_p(P::Gt) {
                break;
            }
        }
        self.expect_p(P::Gt)?;
        Ok(out)
    }

    fn parse_path(&mut self) -> Res<Path> {
        let first = self.ident()?;
        if self.eat_p(P::ColonColon) {
            let name = self.ident()?;
            Ok(Path { qual: Some(first), name })
        } else {
            Ok(Path { qual: None, name: first })
        }
    }

    // ---------------------------------------------------------------- types

    fn check_no_split(&self) -> Res<()> {
        if self.split_gt {
            self.fail()
        } else {
            Ok(())
        }
    }

    fn parse_type(&mut self) -> Res<TypeExpr> {
        let pos = self.pos();
        match self.peek() {
            Some(Tok::P(P::LBracket)) => {
                self.advance();
                let t = self.parse_type()?;
                self.check_no_split()?;
                self.expect_p(P::RBracket)?;
                Ok(TypeExpr { pos, kind: TypeKind::List(Box::new(t)) })
            }
            Some(Tok::P(P::HashBracket)) => {
                self.advance();
                let k = self.parse_type()?;
                self.check_no_split()?;
                self.expect_p(P::Colon)?;
                let v = self.parse_type()?;
                self.check_no_split()?;
                self.expect_p(P::RBracket)?;
                Ok(TypeExpr { pos, kind: TypeKind::Map(Box::new(k), Box::new(v)) })
            }
            Some(Tok::P(P::LParen)) => {
                self.advance();
                let mut parts = vec![self.parse_type()?];
                self.check_no_split()?;
                self.expect_p(P::Comma)?;
                parts.push(self.parse_type()?);
                self.check_no_split()?;
                while self.eat_p(P::Comma) {
                    if self.at_p(P::RParen) {
                        break;
                    }
                    parts.push(self.parse_type()?);
                    self.check_no_split()?;
                }
                self.expect_p(P::RParen)?;
                Ok(TypeExpr { pos, kind: TypeKind::Tuple(parts) })
            }
            Some(Tok::Kw(Kw::Fn)) => {
                self.advance();
                self.expect_p(P::LParen)?;
                let mut params = Vec::new();
                if !self.at_p(P::RParen) {
                    loop {
                        params.push(self.parse_type()?);
                        self.check_no_split()?;
                        if !self.eat_p(P::Comma) || self.at_p(P::RParen) {
                            break;
                        }
                    }
                }
                self.expect_p(P::RParen)?;
                let ret = if self.eat_p(P::Arrow) {
                    let r = self.parse_type()?;
                    Some(Box::new(r))
                } else {
                    None
                };
                Ok(TypeExpr { pos, kind: TypeKind::Fn(params, ret) })
            }
            Some(Tok::Ident(_)) => {
                let path = self.parse_path()?;
                let args = if self.at_p(P::Lt) { self.parse_type_args()? } else { Vec::new() };
                Ok(TypeExpr { pos, kind: TypeKind::Path(path, args) })
            }
            _ => self.fail(),
        }
    }

    fn parse_type_args(&mut self) -> Res<Vec<TypeExpr>> {
        self.expect_p(P::Lt)?;
        self.targ_depth += 1;
        let mut args = vec![self.parse_type()?];
        loop {
            if self.split_gt {
                // The inner list consumed our closing `>` as half of a `>>`.
                self.split_gt = false;
                self.targ_depth -= 1;
                return Ok(args);
            }
            if self.eat_p(P::Comma) {
                if self.at_p(P::Gt) || self.at_p(P::Shr) {
                    break;
                }
                args.push(self.parse_type()?);
                continue;
            }
            break;
        }
        if self.eat_p(P::Gt) {
        } else if self.at_p(P::Shr) {
            if self.targ_depth < 2 {
                return self.fail();
            }
            self.advance();
            self.split_gt = true;
        } else {
            return self.fail();
        }
        self.targ_depth -= 1;
        Ok(args)
    }

    // ----------------------------------------------------------- statements

    fn parse_block(&mut self) -> Res<Block> {
        let pos = self.expect_p(P::LBrace)?;
        let mut stmts = Vec::new();
        let mut tail = None;
        loop {
            if self.eat_p(P::RBrace) {
                break;
            }
            let spos = self.pos();
            match self.peek() {
                Some(Tok::Kw(Kw::Let)) => {
                    self.advance();
                    let pat = self.parse_pat()?;
                    let ty = if self.eat_p(P::Colon) { Some(self.parse_type()?) } else { None };
                    self.expect_p(P::Eq)?;
                    let init = self.parse_expr()?;
                    self.expect_p(P::Semi)?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::Let(pat, ty, init) });
                }
                Some(Tok::Kw(Kw::Var)) => {
                    self.advance();
                    let name = self.ident()?;
                    let ty = if self.eat_p(P::Colon) { Some(self.parse_type()?) } else { None };
                    self.expect_p(P::Eq)?;
                    let init = self.parse_expr()?;
                    self.expect_p(P::Semi)?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::Var(name, ty, init) });
                }
                Some(Tok::Kw(Kw::Return)) => {
                    self.advance();
                    let value = if self.at_p(P::Semi) { None } else { Some(self.parse_expr()?) };
                    self.expect_p(P::Semi)?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::Return(value) });
                }
                Some(Tok::Kw(Kw::While)) => {
                    self.advance();
                    let cond = self.parse_expr()?;
                    let body = self.parse_block()?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::While(cond, body) });
                }
                Some(Tok::Kw(Kw::For)) => {
                    self.advance();
                    let pat = self.parse_pat()?;
                    self.expect_kw(Kw::In)?;
                    let e1 = self.parse_expr()?;
                    let e2 = if self.eat_p(P::DotDot) { Some(self.parse_expr()?) } else { None };
                    let body = self.parse_block()?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::For(pat, e1, e2, body) });
                }
                Some(Tok::Kw(Kw::Break)) => {
                    self.advance();
                    self.expect_p(P::Semi)?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::Break });
                }
                Some(Tok::Kw(Kw::Continue)) => {
                    self.advance();
                    self.expect_p(P::Semi)?;
                    stmts.push(Stmt { pos: spos, kind: StmtKind::Continue });
                }
                _ => {
                    let e = self.parse_expr()?;
                    if self.eat_p(P::Eq) {
                        let value = self.parse_expr()?;
                        self.expect_p(P::Semi)?;
                        stmts.push(Stmt { pos: spos, kind: StmtKind::Assign(e, value) });
                    } else if self.eat_p(P::Semi) {
                        stmts.push(Stmt { pos: spos, kind: StmtKind::Expr(e) });
                    } else if self.at_p(P::RBrace) {
                        self.advance();
                        tail = Some(Box::new(e));
                        break;
                    } else if matches!(e.kind, ExprKind::If(..) | ExprKind::Match(..)) {
                        stmts.push(Stmt { pos: spos, kind: StmtKind::Expr(e) });
                    } else {
                        return self.fail();
                    }
                }
            }
        }
        Ok(Block { pos, stmts, tail })
    }

    // ---------------------------------------------------------- expressions

    /// Parses a full expression.
    fn parse_expr(&mut self) -> Res<Expr> {
        self.parse_or()
    }

    fn bin(l: Expr, op: BinOp, r: Expr) -> Expr {
        Expr { pos: l.pos, kind: ExprKind::Binary(op, Box::new(l), Box::new(r)) }
    }

    fn parse_or(&mut self) -> Res<Expr> {
        let mut l = self.parse_and()?;
        while self.at_p(P::OrOr) {
            self.advance();
            let r = self.parse_and()?;
            l = Self::bin(l, BinOp::Or, r);
        }
        Ok(l)
    }

    fn parse_and(&mut self) -> Res<Expr> {
        let mut l = self.parse_cmp()?;
        while self.at_p(P::AndAnd) {
            self.advance();
            let r = self.parse_cmp()?;
            l = Self::bin(l, BinOp::And, r);
        }
        Ok(l)
    }

    fn parse_cmp(&mut self) -> Res<Expr> {
        let l = self.parse_bitor()?;
        let op = match self.peek() {
            Some(Tok::P(P::EqEq)) => BinOp::Eq,
            Some(Tok::P(P::NotEq)) => BinOp::Ne,
            Some(Tok::P(P::Lt)) => BinOp::Lt,
            Some(Tok::P(P::Le)) => BinOp::Le,
            Some(Tok::P(P::Gt)) => BinOp::Gt,
            Some(Tok::P(P::Ge)) => BinOp::Ge,
            _ => return Ok(l),
        };
        self.advance();
        let r = self.parse_bitor()?;
        Ok(Self::bin(l, op, r))
    }

    fn parse_bitor(&mut self) -> Res<Expr> {
        let mut l = self.parse_bitxor()?;
        while self.at_p(P::Pipe) {
            self.advance();
            let r = self.parse_bitxor()?;
            l = Self::bin(l, BinOp::BitOr, r);
        }
        Ok(l)
    }

    fn parse_bitxor(&mut self) -> Res<Expr> {
        let mut l = self.parse_bitand()?;
        while self.at_p(P::Caret) {
            self.advance();
            let r = self.parse_bitand()?;
            l = Self::bin(l, BinOp::BitXor, r);
        }
        Ok(l)
    }

    fn parse_bitand(&mut self) -> Res<Expr> {
        let mut l = self.parse_shift()?;
        while self.at_p(P::Amp) {
            self.advance();
            let r = self.parse_shift()?;
            l = Self::bin(l, BinOp::BitAnd, r);
        }
        Ok(l)
    }

    fn parse_shift(&mut self) -> Res<Expr> {
        let mut l = self.parse_add()?;
        loop {
            let op = match self.peek() {
                Some(Tok::P(P::Shl)) => BinOp::Shl,
                Some(Tok::P(P::Shr)) => BinOp::Shr,
                _ => return Ok(l),
            };
            self.advance();
            let r = self.parse_add()?;
            l = Self::bin(l, op, r);
        }
    }

    fn parse_add(&mut self) -> Res<Expr> {
        let mut l = self.parse_mul()?;
        loop {
            let op = match self.peek() {
                Some(Tok::P(P::Plus)) => BinOp::Add,
                Some(Tok::P(P::Minus)) => BinOp::Sub,
                Some(Tok::P(P::PlusPlus)) => BinOp::Concat,
                _ => return Ok(l),
            };
            self.advance();
            let r = self.parse_mul()?;
            l = Self::bin(l, op, r);
        }
    }

    fn parse_mul(&mut self) -> Res<Expr> {
        let mut l = self.parse_unary()?;
        loop {
            let op = match self.peek() {
                Some(Tok::P(P::Star)) => BinOp::Mul,
                Some(Tok::P(P::Slash)) => BinOp::Div,
                Some(Tok::P(P::Percent)) => BinOp::Rem,
                _ => return Ok(l),
            };
            self.advance();
            let r = self.parse_unary()?;
            l = Self::bin(l, op, r);
        }
    }

    fn parse_unary(&mut self) -> Res<Expr> {
        let pos = self.pos();
        let op = match self.peek() {
            Some(Tok::P(P::Minus)) => UnOp::Neg,
            Some(Tok::P(P::Bang)) => UnOp::Not,
            Some(Tok::P(P::Tilde)) => UnOp::BitNot,
            _ => return self.parse_postfix(),
        };
        self.advance();
        let e = self.parse_unary()?;
        Ok(Expr { pos, kind: ExprKind::Unary(op, Box::new(e)) })
    }

    fn parse_args(&mut self, close: P) -> Res<Vec<Expr>> {
        let mut args = Vec::new();
        if self.at_p(close) {
            return Ok(args);
        }
        loop {
            args.push(self.parse_expr()?);
            if !self.eat_p(P::Comma) || self.at_p(close) {
                break;
            }
        }
        Ok(args)
    }

    fn parse_postfix(&mut self) -> Res<Expr> {
        let mut e = self.parse_primary()?;
        loop {
            let pos = e.pos;
            match self.peek() {
                Some(Tok::P(P::LParen)) => {
                    self.advance();
                    let args = self.parse_args(P::RParen)?;
                    self.expect_p(P::RParen)?;
                    e = Expr { pos, kind: ExprKind::Call(Box::new(e), args) };
                }
                Some(Tok::P(P::LBracket)) => {
                    self.advance();
                    let idx = self.parse_expr()?;
                    self.expect_p(P::RBracket)?;
                    e = Expr { pos, kind: ExprKind::Index(Box::new(e), Box::new(idx)) };
                }
                Some(Tok::P(P::Dot)) => {
                    self.advance();
                    let name = self.ident()?;
                    if self.eat_p(P::LParen) {
                        let args = self.parse_args(P::RParen)?;
                        self.expect_p(P::RParen)?;
                        e = Expr { pos, kind: ExprKind::MethodCall(Box::new(e), name, args) };
                    } else {
                        e = Expr { pos, kind: ExprKind::Field(Box::new(e), name) };
                    }
                }
                _ => return Ok(e),
            }
        }
    }

    fn parse_primary(&mut self) -> Res<Expr> {
        let pos = self.pos();
        let tok = match self.peek() {
            Some(t) => t.clone(),
            None => return self.fail(),
        };
        match tok {
            Tok::Int(n) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Int(n) })
            }
            Tok::Float(f) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Float(f) })
            }
            Tok::Str(s) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Str(s) })
            }
            Tok::Char(c) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Char(c) })
            }
            Tok::Kw(Kw::True) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Bool(true) })
            }
            Tok::Kw(Kw::False) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::Bool(false) })
            }
            Tok::Kw(Kw::SelfKw) => {
                self.advance();
                Ok(Expr { pos, kind: ExprKind::SelfVal })
            }
            Tok::P(P::LParen) => {
                self.advance();
                let first = self.parse_expr()?;
                if self.eat_p(P::Comma) {
                    let mut parts = vec![first];
                    loop {
                        parts.push(self.parse_expr()?);
                        if !self.eat_p(P::Comma) || self.at_p(P::RParen) {
                            break;
                        }
                    }
                    self.expect_p(P::RParen)?;
                    Ok(Expr { pos, kind: ExprKind::Tuple(parts) })
                } else {
                    self.expect_p(P::RParen)?;
                    Ok(first)
                }
            }
            Tok::P(P::LBracket) => {
                self.advance();
                let items = self.parse_args(P::RBracket)?;
                self.expect_p(P::RBracket)?;
                Ok(Expr { pos, kind: ExprKind::List(items) })
            }
            Tok::P(P::HashBracket) => {
                self.advance();
                let mut entries = Vec::new();
                if !self.at_p(P::RBracket) {
                    loop {
                        let k = self.parse_expr()?;
                        self.expect_p(P::Colon)?;
                        let v = self.parse_expr()?;
                        entries.push((k, v));
                        if !self.eat_p(P::Comma) || self.at_p(P::RBracket) {
                            break;
                        }
                    }
                }
                self.expect_p(P::RBracket)?;
                Ok(Expr { pos, kind: ExprKind::Map(entries) })
            }
            Tok::P(P::Pipe) | Tok::P(P::OrOr) => self.parse_lambda(),
            Tok::Kw(Kw::If) => self.parse_if(),
            Tok::Kw(Kw::Match) => self.parse_match(),
            Tok::Ident(_) => {
                let path = self.parse_path()?;
                if self.at_p(P::Dot) && matches!(self.peek_at(1), Some(Tok::P(P::LBrace))) {
                    self.advance();
                    self.advance();
                    let mut fields = Vec::new();
                    if !self.at_p(P::RBrace) {
                        loop {
                            let name = self.ident()?;
                            self.expect_p(P::Colon)?;
                            let v = self.parse_expr()?;
                            fields.push((name, v));
                            if !self.eat_p(P::Comma) || self.at_p(P::RBrace) {
                                break;
                            }
                        }
                    }
                    self.expect_p(P::RBrace)?;
                    Ok(Expr { pos, kind: ExprKind::StructLit(path, fields) })
                } else {
                    Ok(Expr { pos, kind: ExprKind::Path(path) })
                }
            }
            _ => self.fail(),
        }
    }

    fn parse_lambda(&mut self) -> Res<Expr> {
        let pos = self.pos();
        let mut params = Vec::new();
        if self.eat_p(P::OrOr) {
        } else {
            self.expect_p(P::Pipe)?;
            loop {
                let name = self.ident()?;
                let ty = if self.eat_p(P::Colon) { Some(self.parse_type()?) } else { None };
                params.push(LParam { name, ty });
                if !self.eat_p(P::Comma) || self.at_p(P::Pipe) {
                    break;
                }
            }
            self.expect_p(P::Pipe)?;
        }
        let ret = self.parse_ret()?;
        let body = if self.at_p(P::LBrace) {
            let b = self.parse_block()?;
            Expr { pos: b.pos, kind: ExprKind::Block(Box::new(b)) }
        } else {
            self.parse_expr()?
        };
        Ok(Expr { pos, kind: ExprKind::Lambda(Rc::new(Lambda { params, ret, body })) })
    }

    fn parse_if(&mut self) -> Res<Expr> {
        let pos = self.expect_kw(Kw::If)?;
        let cond = self.parse_expr()?;
        let then = self.parse_block()?;
        let els = if self.eat_kw(Kw::Else) {
            if self.at_kw(Kw::If) {
                Some(Box::new(self.parse_if()?))
            } else {
                let b = self.parse_block()?;
                Some(Box::new(Expr { pos: b.pos, kind: ExprKind::Block(Box::new(b)) }))
            }
        } else {
            None
        };
        Ok(Expr { pos, kind: ExprKind::If(Box::new(cond), Box::new(then), els) })
    }

    fn parse_match(&mut self) -> Res<Expr> {
        let pos = self.expect_kw(Kw::Match)?;
        let scrut = self.parse_expr()?;
        self.expect_p(P::LBrace)?;
        let mut arms = Vec::new();
        while !self.at_p(P::RBrace) {
            let pat = self.parse_pat()?;
            let guard = if self.eat_kw(Kw::When) { Some(self.parse_expr()?) } else { None };
            self.expect_p(P::Arrow)?;
            let (body, block_body) = if self.at_p(P::LBrace) {
                let b = self.parse_block()?;
                (Expr { pos: b.pos, kind: ExprKind::Block(Box::new(b)) }, true)
            } else {
                (self.parse_expr()?, false)
            };
            arms.push(Arm { pat, guard, body });
            if !self.eat_p(P::Comma) && !block_body && !self.at_p(P::RBrace) {
                return self.fail();
            }
        }
        self.expect_p(P::RBrace)?;
        Ok(Expr { pos, kind: ExprKind::Match(Box::new(scrut), arms) })
    }

    // ------------------------------------------------------------- patterns

    fn parse_pat(&mut self) -> Res<Pat> {
        let pos = self.pos();
        let tok = match self.peek() {
            Some(t) => t.clone(),
            None => return self.fail(),
        };
        let kind = match tok {
            Tok::Underscore => {
                self.advance();
                PatKind::Wild
            }
            Tok::Int(n) => {
                self.advance();
                PatKind::Int(n)
            }
            Tok::Float(_) => {
                self.advance();
                PatKind::Float
            }
            Tok::P(P::Minus) => {
                self.advance();
                match self.peek() {
                    Some(Tok::Int(n)) => {
                        let n = *n;
                        self.advance();
                        PatKind::Int(n.wrapping_neg())
                    }
                    Some(Tok::Float(_)) => {
                        self.advance();
                        PatKind::Float
                    }
                    _ => return self.fail(),
                }
            }
            Tok::Str(s) => {
                self.advance();
                PatKind::Str(s)
            }
            Tok::Char(c) => {
                self.advance();
                PatKind::Char(c)
            }
            Tok::Kw(Kw::True) => {
                self.advance();
                PatKind::Bool(true)
            }
            Tok::Kw(Kw::False) => {
                self.advance();
                PatKind::Bool(false)
            }
            Tok::P(P::LParen) => {
                self.advance();
                let mut parts = vec![self.parse_pat()?];
                self.expect_p(P::Comma)?;
                loop {
                    parts.push(self.parse_pat()?);
                    if !self.eat_p(P::Comma) || self.at_p(P::RParen) {
                        break;
                    }
                }
                self.expect_p(P::RParen)?;
                PatKind::Tuple(parts)
            }
            Tok::P(P::LBracket) => {
                self.advance();
                let mut elems = Vec::new();
                let mut rest = None;
                loop {
                    if self.at_p(P::RBracket) {
                        break;
                    }
                    if self.eat_p(P::DotDot) {
                        rest = Some(if self.at_ident() { Some(self.ident()?) } else { None });
                        break;
                    }
                    elems.push(self.parse_pat()?);
                    if !self.eat_p(P::Comma) {
                        break;
                    }
                }
                self.expect_p(P::RBracket)?;
                PatKind::List(elems, rest)
            }
            Tok::Ident(_) => {
                let path = self.parse_path()?;
                if self.at_p(P::Dot) && matches!(self.peek_at(1), Some(Tok::P(P::LBrace))) {
                    self.advance();
                    self.advance();
                    let mut fields = Vec::new();
                    let mut rest = false;
                    loop {
                        if self.at_p(P::RBrace) {
                            break;
                        }
                        if self.eat_p(P::DotDot) {
                            rest = true;
                            break;
                        }
                        let name = self.ident()?;
                        let sub = if self.eat_p(P::Colon) { Some(self.parse_pat()?) } else { None };
                        fields.push((name, sub));
                        if !self.eat_p(P::Comma) {
                            break;
                        }
                    }
                    self.expect_p(P::RBrace)?;
                    PatKind::Struct(path, fields, rest)
                } else if self.eat_p(P::LParen) {
                    let mut subs = vec![self.parse_pat()?];
                    while self.eat_p(P::Comma) {
                        if self.at_p(P::RParen) {
                            break;
                        }
                        subs.push(self.parse_pat()?);
                    }
                    self.expect_p(P::RParen)?;
                    PatKind::Variant(path, Some(subs))
                } else if path.qual.is_some() {
                    PatKind::Variant(path, None)
                } else {
                    PatKind::Ident(path.name.name)
                }
            }
            _ => return self.fail(),
        };
        Ok(Pat { pos, kind })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexer::lex;

    fn parse(s: &str) -> Res<Module> {
        parse_module(lex(s)?, Pos::new(1, 1))
    }

    #[test]
    fn parses_items() {
        let m = parse("fn f(a: Int, b: [Int]) -> Int { a }\nstruct S<T> { x: T }").unwrap();
        assert_eq!(m.items.len(), 2);
    }

    #[test]
    fn comparison_is_non_associative() {
        let e = parse("fn f() { 1 < 2 < 3; }").unwrap_err();
        assert_eq!(e.kind, ErrorKind::Parse);
    }

    #[test]
    fn nested_type_args_close_with_shr() {
        assert!(parse("fn f(x: A<B<C>>) {}").is_ok());
        assert!(parse("fn f(x: A<B<C<D>>>) {}").is_ok());
        assert!(parse("fn f(x: A<B>>) {}").is_err());
    }
}
