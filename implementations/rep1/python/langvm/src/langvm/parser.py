"""Recursive-descent parser for Vellum (SPEC section 4).

``parse_module(tokens, end_pos)`` returns the list of items of one module and
raises a ``parse`` :class:`CompileError` at the first token that cannot be accepted.
"""

from __future__ import annotations

from .diagnostics import CompileError
from .lexer import Token
from . import syntax as S

_BINPREC = {
    "||": 1, "&&": 2,
    "==": 3, "!=": 3, "<": 3, "<=": 3, ">": 3, ">=": 3,
    "|": 4, "^": 5, "&": 6, "<<": 7, ">>": 7,
    "+": 8, "-": 8, "++": 8, "*": 9, "/": 9, "%": 9,
}
_CMP = frozenset(("==", "!=", "<", "<=", ">", ">="))


class Parser:
    def __init__(self, tokens: list[Token], end_pos: tuple[int, int]):
        self.toks = tokens + [Token("eof", None, end_pos[0], end_pos[1])]
        self.i = 0
        self.tok = self.toks[0]

    # ------------------------------------------------------------ helpers
    def fail(self, tok: Token | None = None):
        t = tok or self.tok
        raise CompileError("parse", t.line, t.col)

    def advance(self) -> Token:
        t = self.tok
        self.i += 1
        self.tok = self.toks[self.i] if self.i < len(self.toks) else self.toks[-1]
        return t

    def expect(self, kind: str) -> Token:
        if self.tok.kind != kind:
            self.fail()
        return self.advance()

    def accept(self, kind: str) -> Token | None:
        if self.tok.kind == kind:
            return self.advance()
        return None

    def ident(self) -> Token:
        return self.expect("ident")

    def peek_kind(self, k: int) -> str:
        j = self.i + k
        return self.toks[j].kind if j < len(self.toks) else "eof"

    # -------------------------------------------------------------- items
    def parse_module(self) -> list:
        items = []
        while self.tok.kind != "eof":
            items.append(self.parse_item())
        return items

    def parse_item(self):
        k = self.tok.kind
        if k == "use":
            return self.parse_use()
        if k == "impl":
            return self.parse_impl()
        pub = False
        if k == "pub":
            self.advance()
            pub = True
            k = self.tok.kind
        if k == "fn":
            return self.parse_fn(pub)
        if k == "struct":
            return self.parse_struct(pub)
        if k == "enum":
            return self.parse_enum(pub)
        if k == "trait":
            return self.parse_trait(pub)
        self.fail()

    def parse_use(self):
        kw = self.expect("use")
        m = self.ident()
        alias = alias_pos = None
        if self.accept("as"):
            a = self.ident()
            alias, alias_pos = a.val, a.pos
        self.expect(";")
        return S.Use(kw.pos, m.val, m.pos, alias, alias_pos)

    def parse_generics(self, allow_bounds: bool) -> list:
        params = []
        if self.tok.kind != "<":
            return params
        self.advance()
        while True:
            name = self.ident()
            bounds = []
            if self.tok.kind == ":":
                if not allow_bounds:
                    self.fail()
                self.advance()
                bounds.append(self.parse_trait_ref())
                while self.accept("+"):
                    bounds.append(self.parse_trait_ref())
            params.append(S.GenParam(name.val, name.pos, bounds))
            if self.accept(","):
                if self.tok.kind == ">":
                    break
                continue
            break
        self.expect(">")
        return params

    def parse_trait_ref(self) -> S.TraitRef:
        a = self.ident()
        if self.accept("::"):
            b = self.ident()
            return S.TraitRef(a.pos, a.val, a.pos, b.val, b.pos)
        return S.TraitRef(a.pos, None, None, a.val, a.pos)

    def parse_params(self) -> list:
        params = []
        while True:
            name = self.ident()
            self.expect(":")
            params.append(S.Param(name.val, name.pos, self.parse_type()))
            if self.accept(","):
                if self.tok.kind == ")":
                    break
                continue
            break
        return params

    def parse_ret(self):
        if self.accept("->"):
            return self.parse_type()
        return None

    def parse_fn(self, pub: bool) -> S.FnDecl:
        kw = self.expect("fn")
        name = self.ident()
        tparams = self.parse_generics(True)
        self.expect("(")
        params = [] if self.tok.kind == ")" else self.parse_params()
        self.expect(")")
        ret = self.parse_ret()
        body = self.parse_block()
        return S.FnDecl(kw.pos, name.val, name.pos, tparams, params, ret, body, pub)

    def parse_struct(self, pub: bool) -> S.StructDecl:
        kw = self.expect("struct")
        name = self.ident()
        tparams = self.parse_generics(False)
        self.expect("{")
        fields = []
        while self.tok.kind != "}":
            f = self.ident()
            self.expect(":")
            fields.append(S.FieldDecl(f.val, f.pos, self.parse_type()))
            if not self.accept(","):
                break
        self.expect("}")
        return S.StructDecl(kw.pos, name.val, name.pos, tparams, fields, pub)

    def parse_enum(self, pub: bool) -> S.EnumDecl:
        kw = self.expect("enum")
        name = self.ident()
        tparams = self.parse_generics(False)
        self.expect("{")
        variants = []
        while self.tok.kind != "}":
            v = self.ident()
            payloads = []
            if self.accept("("):
                while True:
                    payloads.append(self.parse_type())
                    if self.accept(","):
                        if self.tok.kind == ")":
                            break
                        continue
                    break
                self.expect(")")
            variants.append(S.VariantDecl(v.val, v.pos, payloads))
            if not self.accept(","):
                break
        self.expect("}")
        return S.EnumDecl(kw.pos, name.val, name.pos, tparams, variants, pub)

    def parse_method(self, allow_no_body: bool) -> S.MethodDecl:
        kw = self.expect("fn")
        name = self.ident()
        self.expect("(")
        self.expect("self")
        params = []
        if self.accept(","):
            params = self.parse_params()
        self.expect(")")
        ret = self.parse_ret()
        body = None
        if allow_no_body and self.tok.kind == ";":
            self.advance()
        else:
            body = self.parse_block()
        return S.MethodDecl(kw.pos, name.val, name.pos, params, ret, body)

    def parse_trait(self, pub: bool) -> S.TraitDecl:
        kw = self.expect("trait")
        name = self.ident()
        self.expect("{")
        methods = []
        while self.tok.kind != "}":
            methods.append(self.parse_method(True))
        self.expect("}")
        return S.TraitDecl(kw.pos, name.val, name.pos, methods, pub)

    def parse_impl(self) -> S.ImplDecl:
        kw = self.expect("impl")
        tparams = self.parse_generics(True)
        trait = self.parse_trait_ref()
        self.expect("for")
        head = self.parse_type()
        self.expect("{")
        methods = []
        while self.tok.kind != "}":
            methods.append(self.parse_method(False))
        self.expect("}")
        return S.ImplDecl(kw.pos, tparams, trait, head, methods)

    # -------------------------------------------------------------- types
    def parse_type(self):
        t = self.tok
        k = t.kind
        if k == "[":
            self.advance()
            elem = self.parse_type()
            self.expect("]")
            return S.TyList(t.pos, elem)
        if k == "#[":
            self.advance()
            key = self.parse_type()
            self.expect(":")
            val = self.parse_type()
            self.expect("]")
            return S.TyMap(t.pos, key, val)
        if k == "(":
            self.advance()
            items = [self.parse_type()]
            self.expect(",")
            while True:
                items.append(self.parse_type())
                if self.accept(","):
                    if self.tok.kind == ")":
                        break
                    continue
                break
            self.expect(")")
            return S.TyTuple(t.pos, items)
        if k == "fn":
            self.advance()
            self.expect("(")
            params = []
            if self.tok.kind != ")":
                while True:
                    params.append(self.parse_type())
                    if self.accept(","):
                        if self.tok.kind == ")":
                            break
                        continue
                    break
            self.expect(")")
            ret = self.parse_ret()
            return S.TyFn(t.pos, params, ret)
        if k == "ident":
            self.advance()
            qual = qual_pos = None
            name, name_pos = t.val, t.pos
            if self.tok.kind == "::":
                self.advance()
                n2 = self.ident()
                qual, qual_pos = name, t.pos
                name, name_pos = n2.val, n2.pos
            args = None
            if self.tok.kind == "<":
                self.advance()
                args = []
                while True:
                    args.append(self.parse_type())
                    if self.accept(","):
                        if self.tok.kind in (">", ">>"):
                            break
                        continue
                    break
                self.close_angle()
            return S.TyName(t.pos, qual, qual_pos, name, name_pos, args)
        self.fail()

    def close_angle(self) -> None:
        if self.tok.kind == ">":
            self.advance()
        elif self.tok.kind == ">>":
            t = self.tok
            self.toks[self.i] = Token(">", None, t.line, t.col + 1)
            self.tok = self.toks[self.i]
        else:
            self.fail()

    # ----------------------------------------------------------- patterns
    def parse_pattern(self):
        t = self.tok
        k = t.kind
        if k == "_":
            self.advance()
            return S.PWild(t.pos)
        if k in ("int", "float"):
            self.advance()
            return S.PLit(t.pos, k, t.val)
        if k == "-":
            self.advance()
            n = self.tok
            if n.kind not in ("int", "float"):
                self.fail()
            self.advance()
            return S.PLit(t.pos, n.kind, -n.val)
        if k in ("str", "char"):
            self.advance()
            return S.PLit(t.pos, k, t.val)
        if k in ("true", "false"):
            self.advance()
            return S.PLit(t.pos, "bool", k == "true")
        if k == "(":
            self.advance()
            items = [self.parse_pattern()]
            self.expect(",")
            while True:
                items.append(self.parse_pattern())
                if self.accept(","):
                    if self.tok.kind == ")":
                        break
                    continue
                break
            self.expect(")")
            return S.PTuple(t.pos, items)
        if k == "[":
            self.advance()
            items = []
            has_rest = False
            rest_name = rest_pos = None
            while self.tok.kind != "]":
                if self.tok.kind == "..":
                    self.advance()
                    has_rest = True
                    if self.tok.kind == "ident":
                        r = self.advance()
                        rest_name, rest_pos = r.val, r.pos
                    break
                items.append(self.parse_pattern())
                if not self.accept(","):
                    break
            self.expect("]")
            return S.PList(t.pos, items, has_rest, rest_name, rest_pos)
        if k == "ident":
            self.advance()
            qual = qual_pos = None
            name, name_pos = t.val, t.pos
            if self.tok.kind == "::":
                self.advance()
                n2 = self.ident()
                qual, qual_pos = name, t.pos
                name, name_pos = n2.val, n2.pos
            if self.tok.kind == "." and self.peek_kind(1) == "{":
                self.advance()
                self.advance()
                fields = []
                rest = False
                while self.tok.kind != "}":
                    if self.tok.kind == "..":
                        self.advance()
                        rest = True
                        break
                    f = self.ident()
                    sub = None
                    if self.accept(":"):
                        sub = self.parse_pattern()
                    fields.append(S.FieldPat(f.val, f.pos, sub))
                    if not self.accept(","):
                        break
                self.expect("}")
                return S.PStruct(t.pos, qual, qual_pos, name, name_pos, fields, rest)
            if self.tok.kind == "(":
                self.advance()
                args = []
                while True:
                    args.append(self.parse_pattern())
                    if self.accept(","):
                        if self.tok.kind == ")":
                            break
                        continue
                    break
                self.expect(")")
                return S.PVariant(t.pos, qual, qual_pos, name, name_pos, args)
            if qual is not None:
                return S.PVariant(t.pos, qual, qual_pos, name, name_pos, None)
            return S.PBind(t.pos, name)
        self.fail()

    # ------------------------------------------------------------- blocks
    def parse_block(self) -> S.Block:
        lb = self.expect("{")
        stmts = []
        tail = None
        while self.tok.kind != "}":
            t = self.tok
            k = t.kind
            if k == "let":
                self.advance()
                pat = self.parse_pattern()
                ty = None
                if self.accept(":"):
                    ty = self.parse_type()
                self.expect("=")
                e = self.parse_expr()
                self.expect(";")
                stmts.append(S.Let(t.pos, pat, ty, e))
            elif k == "var":
                self.advance()
                name = self.ident()
                ty = None
                if self.accept(":"):
                    ty = self.parse_type()
                self.expect("=")
                e = self.parse_expr()
                self.expect(";")
                stmts.append(S.VarDecl(t.pos, name.val, name.pos, ty, e))
            elif k == "return":
                self.advance()
                e = None
                if self.tok.kind != ";":
                    e = self.parse_expr()
                self.expect(";")
                stmts.append(S.Return(t.pos, e))
            elif k == "while":
                self.advance()
                cond = self.parse_expr()
                body = self.parse_block()
                stmts.append(S.While(t.pos, cond, body))
            elif k == "for":
                self.advance()
                pat = self.parse_pattern()
                self.expect("in")
                it = self.parse_expr()
                hi = None
                if self.accept(".."):
                    hi = self.parse_expr()
                body = self.parse_block()
                stmts.append(S.For(t.pos, pat, it, hi, body))
            elif k == "break":
                self.advance()
                self.expect(";")
                stmts.append(S.Break(t.pos))
            elif k == "continue":
                self.advance()
                self.expect(";")
                stmts.append(S.Continue(t.pos))
            else:
                e = self.parse_expr()
                nk = self.tok.kind
                if nk == "=":
                    self.advance()
                    rhs = self.parse_expr()
                    self.expect(";")
                    stmts.append(S.Assign(e.pos, e, rhs))
                elif nk == ";":
                    self.advance()
                    stmts.append(S.ExprStmt(e.pos, e))
                elif nk == "}":
                    tail = e
                    break
                elif isinstance(e, (S.If, S.Match)):
                    stmts.append(S.ExprStmt(e.pos, e))
                else:
                    self.fail()
        self.expect("}")
        return S.Block(lb.pos, stmts, tail)

    # -------------------------------------------------------- expressions
    def parse_expr(self):
        return self.parse_bin(1)

    def parse_bin(self, minp: int):
        left = self.parse_unary()
        did_cmp = False
        while True:
            op = self.tok.kind
            p = _BINPREC.get(op)
            if p is None or p < minp:
                return left
            if p == 3 and did_cmp:
                self.fail()
            self.advance()
            right = self.parse_bin(p + 1)
            left = S.Binary(left.pos, op, left, right)
            if p == 3:
                did_cmp = True

    def parse_unary(self):
        t = self.tok
        if t.kind in ("-", "!", "~"):
            self.advance()
            return S.Unary(t.pos, t.kind, self.parse_unary())
        return self.parse_postfix()

    def parse_args(self, closer: str) -> list:
        args = []
        if self.tok.kind == closer:
            return args
        while True:
            args.append(self.parse_expr())
            if self.accept(","):
                if self.tok.kind == closer:
                    break
                continue
            break
        return args

    def parse_postfix(self):
        e = self.parse_primary()
        while True:
            k = self.tok.kind
            if k == "(":
                self.advance()
                args = self.parse_args(")")
                self.expect(")")
                e = S.Call(e.pos, e, args)
            elif k == "[":
                self.advance()
                idx = self.parse_expr()
                self.expect("]")
                e = S.Index(e.pos, e, idx)
            elif k == ".":
                self.advance()
                name = self.ident()
                if self.tok.kind == "(":
                    self.advance()
                    args = self.parse_args(")")
                    self.expect(")")
                    e = S.MethodCall(e.pos, e, name.val, name.pos, args)
                else:
                    e = S.FieldAccess(e.pos, e, name.val, name.pos)
            else:
                return e

    def parse_primary(self):
        t = self.tok
        k = t.kind
        if k == "int":
            self.advance()
            return S.IntLit(t.pos, t.val)
        if k == "float":
            self.advance()
            return S.FloatLit(t.pos, t.val)
        if k == "str":
            self.advance()
            return S.StrLit(t.pos, t.val)
        if k == "char":
            self.advance()
            return S.CharLit(t.pos, t.val)
        if k == "true" or k == "false":
            self.advance()
            return S.BoolLit(t.pos, k == "true")
        if k == "self":
            self.advance()
            return S.SelfExpr(t.pos)
        if k == "(":
            self.advance()
            e = self.parse_expr()
            if self.tok.kind == ",":
                items = [e]
                self.advance()
                while True:
                    items.append(self.parse_expr())
                    if self.accept(","):
                        if self.tok.kind == ")":
                            break
                        continue
                    break
                self.expect(")")
                return S.TupleLit(t.pos, items)
            self.expect(")")
            return e
        if k == "[":
            self.advance()
            items = self.parse_args("]")
            self.expect("]")
            return S.ListLit(t.pos, items)
        if k == "#[":
            self.advance()
            entries = []
            while self.tok.kind != "]":
                key = self.parse_expr()
                self.expect(":")
                val = self.parse_expr()
                entries.append((key, val))
                if not self.accept(","):
                    break
            self.expect("]")
            return S.MapLit(t.pos, entries)
        if k == "||" or k == "|":
            return self.parse_lambda()
        if k == "if":
            return self.parse_if()
        if k == "match":
            return self.parse_match()
        if k == "ident":
            self.advance()
            qual = qual_pos = None
            name, name_pos = t.val, t.pos
            if self.tok.kind == "::":
                self.advance()
                n2 = self.ident()
                qual, qual_pos = name, t.pos
                name, name_pos = n2.val, n2.pos
            path = S.PathExpr(t.pos, qual, qual_pos, name, name_pos)
            if self.tok.kind == "." and self.peek_kind(1) == "{":
                self.advance()
                self.advance()
                fields = []
                while self.tok.kind != "}":
                    f = self.ident()
                    self.expect(":")
                    fields.append(S.FieldInit(f.val, f.pos, self.parse_expr()))
                    if not self.accept(","):
                        break
                self.expect("}")
                return S.StructLit(t.pos, path, fields)
            return path
        self.fail()

    def parse_lambda(self):
        t = self.advance()
        params = []
        if t.kind == "|":
            while True:
                name = self.ident()
                ty = None
                if self.accept(":"):
                    ty = self.parse_type()
                params.append(S.LParam(name.val, name.pos, ty))
                if self.accept(","):
                    if self.tok.kind == "|":
                        break
                    continue
                break
            self.expect("|")
        ret = self.parse_ret()
        body = self.parse_block() if self.tok.kind == "{" else self.parse_expr()
        return S.Lambda(t.pos, params, ret, body)

    def parse_if(self):
        t = self.expect("if")
        cond = self.parse_expr()
        then = self.parse_block()
        els = None
        if self.accept("else"):
            if self.tok.kind == "if":
                els = self.parse_if()
            else:
                els = self.parse_block()
        return S.If(t.pos, cond, then, els)

    def parse_match(self):
        t = self.expect("match")
        scrut = self.parse_expr()
        self.expect("{")
        arms = []
        while self.tok.kind != "}":
            pat = self.parse_pattern()
            guard = None
            if self.accept("when"):
                guard = self.parse_expr()
            self.expect("->")
            is_block = self.tok.kind == "{"
            body = self.parse_block() if is_block else self.parse_expr()
            arms.append(S.Arm(pat, guard, body, pat.pos))
            if not self.accept(","):
                if self.tok.kind != "}" and not is_block:
                    self.fail()
        self.expect("}")
        return S.Match(t.pos, scrut, arms)

    # ----------------------------------------- builtin signature tables --
    def parse_signatures(self) -> list:
        """Parse ``fn name<T>(params) -> ret;`` declarations (used for the prelude)."""
        sigs = []
        while self.tok.kind != "eof":
            kw = self.expect("fn")
            name = self.ident()
            tparams = self.parse_generics(True)
            self.expect("(")
            params = [] if self.tok.kind == ")" else self.parse_params()
            self.expect(")")
            ret = self.parse_ret()
            self.expect(";")
            sigs.append((name.val, tparams, params, ret))
        return sigs


def parse_module(tokens: list[Token], end_pos: tuple[int, int]) -> list:
    return Parser(tokens, end_pos).parse_module()
