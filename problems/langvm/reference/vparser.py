"""Recursive-descent parser: one token list becomes one list of items."""

from verrors import CompileError
from vast import (
    TAList, TAMap, TATuple, TAFn, TAPath,
    EInt, EFloat, EStr, EChar, EBool, ESelf, EPath, EUnary, EBinary, ECall,
    EMethod, EIndex, EField, EStructLit, EList, EMap, ETuple, ELambda, EIf,
    EMatch, EBlock,
    SLet, SVar, SAssign, SExpr, SWhile, SForSeq, SForRange, SBreak, SContinue,
    SReturn,
    PWild, PInt, PFloat, PStr, PChar, PBool, PVariant, PStruct, PTuple, PList,
    Arm, Param, GenParam, TraitRef,
    IUse, IFn, IStruct, IEnum, ITrait, IImpl, MethodDef, FieldDef, VariantDef,
)

CMP_OPS = ('==', '!=', '<', '<=', '>', '>=')
ADD_OPS = ('+', '-', '++')
MUL_OPS = ('*', '/', '%')
SHIFT_OPS = ('<<', '>>')


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    # --- token helpers -----------------------------------------------------

    def cur(self):
        return self.toks[self.i]

    def kind(self):
        return self.toks[self.i].kind

    def at(self, k):
        return self.toks[self.i].kind == k

    def peek_kind(self, n=1):
        j = self.i + n
        return self.toks[j].kind if j < len(self.toks) else 'eof'

    def take(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def expect(self, k):
        if self.toks[self.i].kind != k:
            self.fail()
        return self.take()

    def fail(self):
        t = self.toks[self.i]
        raise CompileError('parse', t.line, t.col)

    def expect_gt(self):
        """Close one type-argument list; a `>>` token closes two."""
        t = self.toks[self.i]
        if t.kind == '>':
            self.i += 1
        elif t.kind == '>>':
            t.kind = '>'
            t.col = t.col + 1
        else:
            self.fail()

    # --- items -------------------------------------------------------------

    def parse_items(self):
        items = []
        while not self.at('eof'):
            items.append(self.parse_item())
        return items

    def parse_item(self):
        if self.at('use'):
            return self.parse_use()
        pub = False
        if self.at('pub'):
            self.take()
            pub = True
        k = self.kind()
        if k == 'fn':
            return self.parse_fn(pub)
        if k == 'struct':
            return self.parse_struct(pub)
        if k == 'enum':
            return self.parse_enum(pub)
        if k == 'trait':
            return self.parse_trait(pub)
        if k == 'impl' and not pub:
            return self.parse_impl()
        self.fail()

    def parse_use(self):
        kw = self.expect('use')
        name = self.expect('ident')
        alias = None
        if self.at('as'):
            self.take()
            alias = self.expect('ident')
        self.expect(';')
        it = IUse()
        it.line, it.col = kw.line, kw.col
        it.name = name.val
        it.nline, it.ncol = name.line, name.col
        it.alias = alias.val if alias else None
        it.aline = alias.line if alias else name.line
        it.acol = alias.col if alias else name.col
        return it

    def parse_generics(self, allow_bounds):
        if not self.at('<'):
            return []
        self.take()
        out = []
        while True:
            name = self.expect('ident')
            bounds = []
            if self.at(':'):
                if not allow_bounds:
                    self.fail()
                self.take()
                bounds.append(self.parse_trait_ref())
                while self.at('+'):
                    self.take()
                    bounds.append(self.parse_trait_ref())
            out.append(GenParam(name.val, bounds, name.line, name.col))
            if self.at(','):
                self.take()
                if self.at('>') or self.at('>>'):
                    break
                continue
            break
        self.expect_gt()
        return out

    def parse_trait_ref(self):
        first = self.expect('ident')
        mod = None
        name = first
        if self.at('::'):
            self.take()
            mod = first.val
            name = self.expect('ident')
        return TraitRef(mod, name.val, first.line, first.col,
                        name.line, name.col)

    def parse_params(self, closing=')'):
        out = []
        if self.at(closing):
            return out
        while True:
            name = self.expect('ident')
            self.expect(':')
            ann = self.parse_type()
            out.append(Param(name.val, ann, name.line, name.col))
            if self.at(','):
                self.take()
                if self.at(closing):
                    break
                continue
            break
        return out

    def parse_fn(self, pub):
        kw = self.expect('fn')
        name = self.expect('ident')
        generics = self.parse_generics(True)
        self.expect('(')
        params = self.parse_params()
        self.expect(')')
        ret = None
        if self.at('->'):
            self.take()
            ret = self.parse_type()
        body = self.parse_block()
        it = IFn()
        it.line, it.col = kw.line, kw.col
        it.pub = pub
        it.name = name.val
        it.nline, it.ncol = name.line, name.col
        it.generics = generics
        it.params = params
        it.ret = ret
        it.body = body
        it.sig = None
        it.info = None
        return it

    def parse_struct(self, pub):
        kw = self.expect('struct')
        name = self.expect('ident')
        generics = self.parse_generics(False)
        self.expect('{')
        fields = []
        if not self.at('}'):
            while True:
                fname = self.expect('ident')
                self.expect(':')
                ann = self.parse_type()
                fields.append(FieldDef(fname.val, ann, fname.line, fname.col))
                if self.at(','):
                    self.take()
                    if self.at('}'):
                        break
                    continue
                break
        self.expect('}')
        it = IStruct()
        it.line, it.col = kw.line, kw.col
        it.pub = pub
        it.name = name.val
        it.nline, it.ncol = name.line, name.col
        it.generics = generics
        it.fields = fields
        it.decl = None
        return it

    def parse_enum(self, pub):
        kw = self.expect('enum')
        name = self.expect('ident')
        generics = self.parse_generics(False)
        self.expect('{')
        variants = []
        if not self.at('}'):
            while True:
                vname = self.expect('ident')
                payloads = []
                if self.at('('):
                    self.take()
                    while True:
                        payloads.append(self.parse_type())
                        if self.at(','):
                            self.take()
                            if self.at(')'):
                                break
                            continue
                        break
                    self.expect(')')
                variants.append(
                    VariantDef(vname.val, payloads, vname.line, vname.col))
                if self.at(','):
                    self.take()
                    if self.at('}'):
                        break
                    continue
                break
        self.expect('}')
        it = IEnum()
        it.line, it.col = kw.line, kw.col
        it.pub = pub
        it.name = name.val
        it.nline, it.ncol = name.line, name.col
        it.generics = generics
        it.variants = variants
        it.decl = None
        return it

    def parse_method(self, need_body):
        kw = self.expect('fn')
        name = self.expect('ident')
        self.expect('(')
        self.expect('self')
        params = []
        if self.at(','):
            self.take()
            params = self.parse_params()
        self.expect(')')
        ret = None
        if self.at('->'):
            self.take()
            ret = self.parse_type()
        if need_body:
            body = self.parse_block()
        elif self.at(';'):
            self.take()
            body = None
        else:
            body = self.parse_block()
        return MethodDef(name.val, name.line, name.col, kw.line, kw.col,
                         params, ret, body)

    def parse_trait(self, pub):
        kw = self.expect('trait')
        name = self.expect('ident')
        self.expect('{')
        methods = []
        while not self.at('}'):
            methods.append(self.parse_method(False))
        self.expect('}')
        it = ITrait()
        it.line, it.col = kw.line, kw.col
        it.pub = pub
        it.name = name.val
        it.nline, it.ncol = name.line, name.col
        it.methods = methods
        it.decl = None
        return it

    def parse_impl(self):
        kw = self.expect('impl')
        generics = self.parse_generics(True)
        tref = self.parse_trait_ref()
        self.expect('for')
        head = self.parse_type()
        self.expect('{')
        methods = []
        while not self.at('}'):
            methods.append(self.parse_method(True))
        self.expect('}')
        it = IImpl()
        it.line, it.col = kw.line, kw.col
        it.generics = generics
        it.traitref = tref
        it.head = head
        it.methods = methods
        it.impl = None
        return it

    # --- types -------------------------------------------------------------

    def parse_type(self):
        t = self.cur()
        k = t.kind
        if k == '[':
            self.take()
            elem = self.parse_type()
            self.expect(']')
            return TAList(t.line, t.col, elem)
        if k == '#[':
            self.take()
            key = self.parse_type()
            self.expect(':')
            val = self.parse_type()
            self.expect(']')
            return TAMap(t.line, t.col, key, val)
        if k == '(':
            self.take()
            parts = [self.parse_type()]
            if not self.at(','):
                self.fail()
            while self.at(','):
                self.take()
                if self.at(')'):
                    break
                parts.append(self.parse_type())
            self.expect(')')
            if len(parts) < 2:
                self.fail()
            return TATuple(t.line, t.col, parts)
        if k == 'fn':
            self.take()
            self.expect('(')
            params = []
            if not self.at(')'):
                while True:
                    params.append(self.parse_type())
                    if self.at(','):
                        self.take()
                        if self.at(')'):
                            break
                        continue
                    break
            self.expect(')')
            ret = None
            if self.at('->'):
                self.take()
                ret = self.parse_type()
            return TAFn(t.line, t.col, params, ret)
        if k == 'ident':
            first = self.take()
            mod = None
            name = first
            if self.at('::'):
                self.take()
                mod = first.val
                name = self.expect('ident')
            args = []
            if self.at('<'):
                self.take()
                while True:
                    args.append(self.parse_type())
                    if self.at(','):
                        self.take()
                        if self.at('>') or self.at('>>'):
                            break
                        continue
                    break
                self.expect_gt()
            return TAPath(first.line, first.col, mod, name.val, args,
                          name.line, name.col)
        self.fail()

    # --- blocks and statements ---------------------------------------------

    def parse_block(self):
        lb = self.expect('{')
        stmts = []
        tail = None
        while not self.at('}'):
            k = self.kind()
            if k == 'let':
                stmts.append(self.parse_let())
            elif k == 'var':
                stmts.append(self.parse_var())
            elif k == 'return':
                stmts.append(self.parse_return())
            elif k == 'while':
                stmts.append(self.parse_while())
            elif k == 'for':
                stmts.append(self.parse_for())
            elif k == 'break':
                t = self.take()
                self.expect(';')
                stmts.append(SBreak(t.line, t.col))
            elif k == 'continue':
                t = self.take()
                self.expect(';')
                stmts.append(SContinue(t.line, t.col))
            else:
                e = self.parse_expr()
                if self.at('='):
                    self.take()
                    rhs = self.parse_expr()
                    self.expect(';')
                    stmts.append(SAssign(e.line, e.col, e, rhs, None))
                elif self.at(';'):
                    self.take()
                    stmts.append(SExpr(e.line, e.col, e))
                elif self.at('}'):
                    tail = e
                    break
                elif isinstance(e, (EIf, EMatch)):
                    stmts.append(SExpr(e.line, e.col, e))
                else:
                    self.fail()
        self.expect('}')
        return EBlock(lb.line, lb.col, stmts, tail, None)

    def parse_let(self):
        kw = self.expect('let')
        pat = self.parse_pattern()
        ann = None
        if self.at(':'):
            self.take()
            ann = self.parse_type()
        self.expect('=')
        e = self.parse_expr()
        self.expect(';')
        return SLet(kw.line, kw.col, pat, ann, e)

    def parse_var(self):
        kw = self.expect('var')
        name = self.expect('ident')
        ann = None
        if self.at(':'):
            self.take()
            ann = self.parse_type()
        self.expect('=')
        e = self.parse_expr()
        self.expect(';')
        st = SVar(kw.line, kw.col, name.val, ann, e, None)
        return st

    def parse_return(self):
        kw = self.expect('return')
        e = None
        if not self.at(';'):
            e = self.parse_expr()
        self.expect(';')
        return SReturn(kw.line, kw.col, e)

    def parse_while(self):
        kw = self.expect('while')
        cond = self.parse_expr()
        body = self.parse_block()
        return SWhile(kw.line, kw.col, cond, body)

    def parse_for(self):
        kw = self.expect('for')
        pat = self.parse_pattern()
        self.expect('in')
        e1 = self.parse_expr()
        if self.at('..'):
            self.take()
            e2 = self.parse_expr()
            body = self.parse_block()
            return SForRange(kw.line, kw.col, pat, e1, e2, body)
        body = self.parse_block()
        return SForSeq(kw.line, kw.col, pat, e1, body, None)

    # --- expressions -------------------------------------------------------

    def parse_expr(self):
        return self.parse_or()

    def parse_or(self):
        left = self.parse_and()
        while self.at('||'):
            self.take()
            right = self.parse_and()
            left = EBinary(left.line, left.col, '||', left, right, None)
        return left

    def parse_and(self):
        left = self.parse_cmp()
        while self.at('&&'):
            self.take()
            right = self.parse_cmp()
            left = EBinary(left.line, left.col, '&&', left, right, None)
        return left

    def parse_cmp(self):
        left = self.parse_bitor()
        if self.kind() in CMP_OPS:
            op = self.take().kind
            right = self.parse_bitor()
            left = EBinary(left.line, left.col, op, left, right, None)
        return left

    def parse_bitor(self):
        left = self.parse_bitxor()
        while self.at('|'):
            self.take()
            right = self.parse_bitxor()
            left = EBinary(left.line, left.col, '|', left, right, None)
        return left

    def parse_bitxor(self):
        left = self.parse_bitand()
        while self.at('^'):
            self.take()
            right = self.parse_bitand()
            left = EBinary(left.line, left.col, '^', left, right, None)
        return left

    def parse_bitand(self):
        left = self.parse_shift()
        while self.at('&'):
            self.take()
            right = self.parse_shift()
            left = EBinary(left.line, left.col, '&', left, right, None)
        return left

    def parse_shift(self):
        left = self.parse_add()
        while self.kind() in SHIFT_OPS:
            op = self.take().kind
            right = self.parse_add()
            left = EBinary(left.line, left.col, op, left, right, None)
        return left

    def parse_add(self):
        left = self.parse_mul()
        while self.kind() in ADD_OPS:
            op = self.take().kind
            right = self.parse_mul()
            left = EBinary(left.line, left.col, op, left, right, None)
        return left

    def parse_mul(self):
        left = self.parse_unary()
        while self.kind() in MUL_OPS:
            op = self.take().kind
            right = self.parse_unary()
            left = EBinary(left.line, left.col, op, left, right, None)
        return left

    def parse_unary(self):
        k = self.kind()
        if k in ('-', '!', '~'):
            t = self.take()
            operand = self.parse_unary()
            return EUnary(t.line, t.col, k, operand, None)
        return self.parse_postfix()

    def parse_postfix(self):
        e = self.parse_primary()
        while True:
            k = self.kind()
            if k == '(':
                self.take()
                args = self.parse_args(')')
                self.expect(')')
                e = ECall(e.line, e.col, e, args, None)
            elif k == '[':
                self.take()
                idx = self.parse_expr()
                self.expect(']')
                e = EIndex(e.line, e.col, e, idx, None)
            elif k == '.' and self.peek_kind() == 'ident':
                self.take()
                name = self.take()
                if self.at('('):
                    self.take()
                    args = self.parse_args(')')
                    self.expect(')')
                    e = EMethod(e.line, e.col, e, name.val, args,
                                name.line, name.col, None)
                else:
                    e = EField(e.line, e.col, e, name.val,
                               name.line, name.col, None)
            else:
                return e

    def parse_args(self, closing):
        args = []
        if self.at(closing):
            return args
        while True:
            args.append(self.parse_expr())
            if self.at(','):
                self.take()
                if self.at(closing):
                    break
                continue
            break
        return args

    def parse_primary(self):
        t = self.cur()
        k = t.kind
        if k == 'int':
            self.take()
            return EInt(t.line, t.col, t.val)
        if k == 'float':
            self.take()
            return EFloat(t.line, t.col, t.val)
        if k == 'str':
            self.take()
            return EStr(t.line, t.col, t.val)
        if k == 'char':
            self.take()
            return EChar(t.line, t.col, t.val)
        if k == 'true':
            self.take()
            return EBool(t.line, t.col, True)
        if k == 'false':
            self.take()
            return EBool(t.line, t.col, False)
        if k == 'self':
            self.take()
            return ESelf(t.line, t.col, None)
        if k == '(':
            self.take()
            first = self.parse_expr()
            if self.at(')'):
                self.take()
                return first
            parts = [first]
            while self.at(','):
                self.take()
                if self.at(')'):
                    break
                parts.append(self.parse_expr())
            self.expect(')')
            if len(parts) < 2:
                self.fail()
            return ETuple(t.line, t.col, parts)
        if k == '[':
            self.take()
            elems = self.parse_args(']')
            self.expect(']')
            return EList(t.line, t.col, elems)
        if k == '#[':
            self.take()
            entries = []
            if not self.at(']'):
                while True:
                    key = self.parse_expr()
                    self.expect(':')
                    val = self.parse_expr()
                    entries.append((key, val))
                    if self.at(','):
                        self.take()
                        if self.at(']'):
                            break
                        continue
                    break
            self.expect(']')
            return EMap(t.line, t.col, entries)
        if k == '||' or k == '|':
            return self.parse_lambda()
        if k == 'if':
            return self.parse_if()
        if k == 'match':
            return self.parse_match()
        if k == 'ident':
            first = self.take()
            mod = None
            name = first
            if self.at('::'):
                self.take()
                mod = first.val
                name = self.expect('ident')
            if self.at('.') and self.peek_kind() == '{':
                self.take()
                self.take()
                fields = []
                if not self.at('}'):
                    while True:
                        fname = self.expect('ident')
                        self.expect(':')
                        val = self.parse_expr()
                        fields.append((fname.val, fname.line, fname.col, val))
                        if self.at(','):
                            self.take()
                            if self.at('}'):
                                break
                            continue
                        break
                self.expect('}')
                path = TAPath(first.line, first.col, mod, name.val, [],
                              name.line, name.col)
                return EStructLit(first.line, first.col, path, fields,
                                  None, None)
            return EPath(first.line, first.col, mod, name.val,
                         name.line, name.col, None)
        self.fail()

    def parse_lambda(self):
        t = self.cur()
        params = []
        if self.at('||'):
            self.take()
        else:
            self.expect('|')
            # LParams needs at least one parameter; the zero-parameter lambda is
            # spelled with the single `||` token.
            while True:
                name = self.expect('ident')
                ann = None
                if self.at(':'):
                    self.take()
                    ann = self.parse_type()
                params.append(Param(name.val, ann, name.line, name.col))
                if self.at(','):
                    self.take()
                    if self.at('|'):
                        break
                    continue
                break
            self.expect('|')
        ret = None
        if self.at('->'):
            self.take()
            ret = self.parse_type()
        if self.at('{'):
            body = self.parse_block()
        else:
            body = self.parse_expr()
        return ELambda(t.line, t.col, params, ret, body, None)

    def parse_if(self):
        kw = self.expect('if')
        cond = self.parse_expr()
        then = self.parse_block()
        els = None
        if self.at('else'):
            self.take()
            if self.at('if'):
                els = self.parse_if()
            else:
                els = self.parse_block()
        return EIf(kw.line, kw.col, cond, then, els)

    def parse_match(self):
        kw = self.expect('match')
        scrut = self.parse_expr()
        self.expect('{')
        arms = []
        if not self.at('}'):
            while True:
                arm = self.parse_arm()
                arms.append(arm)
                if self.at(','):
                    self.take()
                    if self.at('}'):
                        break
                    continue
                if self.at('}'):
                    break
                if arm.block:
                    continue
                self.fail()
        self.expect('}')
        return EMatch(kw.line, kw.col, scrut, arms)

    def parse_arm(self):
        start = self.cur()
        pat = self.parse_pattern()
        guard = None
        if self.at('when'):
            self.take()
            guard = self.parse_expr()
        self.expect('->')
        if self.at('{'):
            body = self.parse_block()
            block = True
        else:
            body = self.parse_expr()
            block = False
        return Arm(pat, guard, body, block, start.line, start.col)

    # --- patterns ----------------------------------------------------------

    def parse_pattern(self):
        t = self.cur()
        k = t.kind
        if k == '_':
            self.take()
            return PWild(t.line, t.col)
        if k == 'int':
            self.take()
            return PInt(t.line, t.col, t.val)
        if k == 'float':
            self.take()
            return PFloat(t.line, t.col, t.val)
        if k == '-':
            self.take()
            n = self.cur()
            if n.kind == 'int':
                self.take()
                return PInt(t.line, t.col, -n.val)
            if n.kind == 'float':
                self.take()
                return PFloat(t.line, t.col, -n.val)
            self.fail()
        if k == 'str':
            self.take()
            return PStr(t.line, t.col, t.val)
        if k == 'char':
            self.take()
            return PChar(t.line, t.col, t.val)
        if k == 'true':
            self.take()
            return PBool(t.line, t.col, True)
        if k == 'false':
            self.take()
            return PBool(t.line, t.col, False)
        if k == '(':
            self.take()
            parts = [self.parse_pattern()]
            if not self.at(','):
                self.fail()
            while self.at(','):
                self.take()
                if self.at(')'):
                    break
                parts.append(self.parse_pattern())
            self.expect(')')
            if len(parts) < 2:
                self.fail()
            return PTuple(t.line, t.col, parts)
        if k == '[':
            self.take()
            elems = []
            rest = False
            restname = None
            if not self.at(']'):
                if self.at('..'):
                    self.take()
                    rest = True
                    if self.at('ident'):
                        restname = self.take().val
                else:
                    while True:
                        elems.append(self.parse_pattern())
                        if self.at(','):
                            self.take()
                            if self.at(']') or self.at('..'):
                                break
                            continue
                        break
                    if self.at('..'):
                        self.take()
                        rest = True
                        if self.at('ident'):
                            restname = self.take().val
            self.expect(']')
            return PList(t.line, t.col, elems, rest, restname, None)
        if k == 'ident':
            first = self.take()
            mod = None
            name = first
            if self.at('::'):
                self.take()
                mod = first.val
                name = self.expect('ident')
            if self.at('.') and self.peek_kind() == '{':
                self.take()
                self.take()
                fields = []
                rest = False
                if not self.at('}'):
                    if self.at('..'):
                        self.take()
                        rest = True
                    else:
                        while True:
                            fname = self.expect('ident')
                            sub = None
                            if self.at(':'):
                                self.take()
                                sub = self.parse_pattern()
                            fields.append((fname.val, fname.line, fname.col,
                                           sub))
                            if self.at(','):
                                self.take()
                                if self.at('}'):
                                    break
                                if self.at('..'):
                                    self.take()
                                    rest = True
                                    break
                                continue
                            if self.at('..'):
                                self.take()
                                rest = True
                            break
                self.expect('}')
                return PStruct(first.line, first.col, mod, name.val, fields,
                               rest, None, None)
            subs = None
            if self.at('('):
                self.take()
                subs = []
                while True:
                    subs.append(self.parse_pattern())
                    if self.at(','):
                        self.take()
                        if self.at(')'):
                            break
                        continue
                    break
                self.expect(')')
            return PVariant(first.line, first.col, mod, name.val, subs, None,
                            None)
        self.fail()


def parse(toks):
    return Parser(toks).parse_items()
