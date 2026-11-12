"""Recursive-descent parser for the minisql SQL dialect."""

from __future__ import annotations

from .errors import SqlSyntaxError
from .lexer import EOF_TOKEN, Token
from .syntax import (
    Agg, Bin, Col, CreateTable, Delete, Insert, IsNull, Like, Lit, Neg, Node,
    Not, OrderTerm, Select, SelectItem, Star, Statement, TableRef, Update,
)

_AGGREGATES = frozenset({"count", "sum", "min", "max", "avg"})
_REL_OPS = frozenset({"<", "<=", ">", ">="})
_EQ_OPS = frozenset({"=", "!="})


def parse_statement(tokens: list[Token]) -> Statement:
    """Parse the tokens of one statement (without its ``;``).

    Raises :class:`SqlSyntaxError` if they do not form exactly one statement.
    """
    return _Parser(tokens).statement()


class _Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.toks = tokens
        self.pos = 0

    # -- token helpers

    def peek(self) -> Token:
        return self.toks[self.pos] if self.pos < len(self.toks) else EOF_TOKEN

    def advance(self) -> Token:
        tok = self.peek()
        self.pos += 1
        return tok

    def fail(self, what: str) -> SqlSyntaxError:
        tok = self.peek()
        got = "end of statement" if tok.kind == "eof" else repr(tok.value)
        return SqlSyntaxError(f"expected {what}, got {got}")

    def at_kw(self, *names: str) -> bool:
        tok = self.peek()
        return tok.kind == "kw" and tok.value in names

    def at_op(self, op: str) -> bool:
        tok = self.peek()
        return tok.kind == "op" and tok.value == op

    def accept_kw(self, name: str) -> bool:
        if self.at_kw(name):
            self.pos += 1
            return True
        return False

    def accept_op(self, op: str) -> bool:
        if self.at_op(op):
            self.pos += 1
            return True
        return False

    def expect_kw(self, name: str) -> None:
        if not self.accept_kw(name):
            raise self.fail(name)

    def expect_op(self, op: str) -> None:
        if not self.accept_op(op):
            raise self.fail(repr(op))

    def name(self) -> str:
        tok = self.peek()
        if tok.kind != "ident":
            raise self.fail("a name")
        self.pos += 1
        return tok.value  # type: ignore[return-value]

    # -- statements

    def statement(self) -> Statement:
        tok = self.peek()
        if tok.kind != "kw":
            raise self.fail("a statement")
        handlers = {
            "CREATE": self.create_table,
            "INSERT": self.insert,
            "DELETE": self.delete,
            "UPDATE": self.update,
            "SELECT": self.select,
        }
        handler = handlers.get(tok.value)  # type: ignore[arg-type]
        if handler is None:
            raise self.fail("a statement")
        self.pos += 1
        stmt = handler()
        if self.peek().kind != "eof":
            raise self.fail("end of statement")
        return stmt

    def create_table(self) -> CreateTable:
        self.expect_kw("TABLE")
        name = self.name()
        self.expect_op("(")
        columns = []
        while True:
            columns.append(self.name())
            if not (self.accept_kw("INTEGER") or self.accept_kw("TEXT")):
                raise self.fail("a column type (INTEGER or TEXT)")
            if not self.accept_op(","):
                break
        self.expect_op(")")
        return CreateTable(name, columns)

    def insert(self) -> Insert:
        self.expect_kw("INTO")
        table = self.name()
        self.expect_kw("VALUES")
        rows = []
        while True:
            self.expect_op("(")
            row = [self.expr()]
            while self.accept_op(","):
                row.append(self.expr())
            self.expect_op(")")
            rows.append(row)
            if not self.accept_op(","):
                break
        return Insert(table, rows)

    def delete(self) -> Delete:
        self.expect_kw("FROM")
        table = self.name()
        where = self.expr() if self.accept_kw("WHERE") else None
        return Delete(table, where)

    def update(self) -> Update:
        table = self.name()
        self.expect_kw("SET")
        assignments = []
        while True:
            column = self.name()
            self.expect_op("=")
            assignments.append((column, self.expr()))
            if not self.accept_op(","):
                break
        where = self.expr() if self.accept_kw("WHERE") else None
        return Update(table, assignments, where)

    def select(self) -> Select:
        items: list[SelectItem | Star] = []
        while True:
            if self.accept_op("*"):
                items.append(Star())
            else:
                expr = self.expr()
                alias = None
                if self.accept_kw("AS"):
                    alias = self.name()
                elif self.peek().kind == "ident":
                    alias = self.name()
                items.append(SelectItem(expr, alias))
            if not self.accept_op(","):
                break
        sel = Select(items)
        if self.accept_kw("FROM"):
            sel.tables.append(self.table_ref())
            if self.accept_op(","):
                sel.tables.append(self.table_ref())
            elif self.at_kw("INNER", "JOIN"):
                if self.accept_kw("INNER"):
                    self.expect_kw("JOIN")
                else:
                    self.pos += 1
                sel.tables.append(self.table_ref())
                self.expect_kw("ON")
                sel.on = self.expr()
        if self.accept_kw("WHERE"):
            sel.where = self.expr()
        if self.accept_kw("GROUP"):
            self.expect_kw("BY")
            sel.group_by.append(self.column_ref())
            while self.accept_op(","):
                sel.group_by.append(self.column_ref())
        if self.at_kw("HAVING"):
            if not sel.group_by:
                raise SqlSyntaxError("HAVING requires GROUP BY")
            self.pos += 1
            sel.having = self.expr()
        if self.accept_kw("ORDER"):
            self.expect_kw("BY")
            sel.order_by.append(self.order_term())
            while self.accept_op(","):
                sel.order_by.append(self.order_term())
        if self.accept_kw("LIMIT"):
            sel.limit = self.integer()
            if self.accept_kw("OFFSET"):
                sel.offset = self.integer()
        return sel

    def integer(self) -> int:
        tok = self.peek()
        if tok.kind != "int":
            raise self.fail("a non-negative integer")
        self.pos += 1
        return tok.value  # type: ignore[return-value]

    def table_ref(self) -> TableRef:
        name = self.name()
        alias = None
        if self.accept_kw("AS"):
            alias = self.name()
        elif self.peek().kind == "ident":
            alias = self.name()
        return TableRef(name, alias)

    def column_ref(self) -> Col:
        first = self.name()
        if self.accept_op("."):
            return Col(first, self.name())
        return Col(None, first)

    def order_term(self) -> OrderTerm:
        start = self.pos
        expr = self.expr()
        term = OrderTerm(expr, False)
        if self.pos - start == 1:  # a single token: maybe an ordinal or alias
            tok = self.toks[start]
            if tok.kind == "int":
                term.ordinal = tok.value  # type: ignore[assignment]
            elif tok.kind == "ident":
                term.alias = tok.value  # type: ignore[assignment]
        if self.accept_kw("DESC"):
            term.descending = True
        else:
            self.accept_kw("ASC")
        return term

    # -- expressions (lowest to highest precedence)

    def expr(self) -> Node:
        left = self.and_expr()
        while self.accept_kw("OR"):
            left = Bin("OR", left, self.and_expr())
        return left

    def and_expr(self) -> Node:
        left = self.not_expr()
        while self.accept_kw("AND"):
            left = Bin("AND", left, self.not_expr())
        return left

    def not_expr(self) -> Node:
        if self.accept_kw("NOT"):
            return Not(self.not_expr())
        return self.eq_expr()

    def eq_expr(self) -> Node:
        left = self.rel_expr()
        while True:
            tok = self.peek()
            if tok.kind == "op" and tok.value in _EQ_OPS:
                self.pos += 1
                left = Bin(tok.value, left, self.rel_expr())  # type: ignore[arg-type]
            elif tok.kind == "kw" and tok.value == "IS":
                self.pos += 1
                negated = self.accept_kw("NOT")
                self.expect_kw("NULL")
                left = IsNull(left, negated)
            elif tok.kind == "kw" and tok.value in ("NOT", "LIKE"):
                negated = self.accept_kw("NOT")
                self.expect_kw("LIKE")
                left = Like(left, self.rel_expr(), negated)
            else:
                return left

    def rel_expr(self) -> Node:
        left = self.add_expr()
        while True:
            tok = self.peek()
            if tok.kind == "op" and tok.value in _REL_OPS:
                self.pos += 1
                left = Bin(tok.value, left, self.add_expr())  # type: ignore[arg-type]
            else:
                return left

    def add_expr(self) -> Node:
        left = self.mul_expr()
        while True:
            tok = self.peek()
            if tok.kind == "op" and tok.value in ("+", "-"):
                self.pos += 1
                left = Bin(tok.value, left, self.mul_expr())  # type: ignore[arg-type]
            else:
                return left

    def mul_expr(self) -> Node:
        left = self.unary()
        while True:
            tok = self.peek()
            if tok.kind == "op" and tok.value in ("*", "/", "%"):
                self.pos += 1
                left = Bin(tok.value, left, self.unary())  # type: ignore[arg-type]
            else:
                return left

    def unary(self) -> Node:
        if self.accept_op("-"):
            return Neg(self.unary())
        return self.primary()

    def primary(self) -> Node:
        tok = self.peek()
        kind = tok.kind
        if kind == "int" or kind == "str":
            self.pos += 1
            return Lit(tok.value)  # type: ignore[arg-type]
        if kind == "kw" and tok.value == "NULL":
            self.pos += 1
            return Lit(None)
        if kind == "op" and tok.value == "(":
            self.pos += 1
            inner = self.expr()
            self.expect_op(")")
            return inner
        if kind == "ident":
            nxt = self.toks[self.pos + 1] if self.pos + 1 < len(self.toks) else EOF_TOKEN
            if nxt.kind == "op" and nxt.value == "(":
                return self.aggregate()
            return self.column_ref()
        raise self.fail("an expression")

    def aggregate(self) -> Agg:
        func = self.name()
        if func not in _AGGREGATES:
            raise SqlSyntaxError(f"unknown function {func!r}")
        self.expect_op("(")
        if func == "count" and self.accept_op("*"):
            arg = None
        else:
            arg = self.expr()
        self.expect_op(")")
        return Agg(func, arg)
