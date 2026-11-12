/// The recursive-descent parser (SPEC.md section 4).
module langvm.parser;

import langvm.ast;
import langvm.diag;
import langvm.lexer;

/// Parse the tokens of one module into its items. Throws `parse` errors.
Item[] parseModule(Token[] toks)
{
    auto p = Parser(toks);
    Item[] items;
    while (p.k != T.eof)
        items ~= p.parseItem();
    return items;
}

private struct Parser
{
    Token[] toks;
    size_t p;
    /// Number of `TypeArgs` lists currently open (for the `>>` token).
    int typeArgDepth;
    /// A `>>` closed two lists; the second `>` is still owed to the outer one.
    bool pendingGt;

    this(Token[] toks)
    {
        this.toks = toks;
    }

    // ------------------------------------------------------------ helpers

    ref const(Token) cur() const
    {
        return toks[p];
    }

    T k() const
    {
        return toks[p].kind;
    }

    T kAt(size_t n) const
    {
        return p + n < toks.length ? toks[p + n].kind : T.eof;
    }

    Pos pos() const
    {
        return toks[p].pos;
    }

    Token take()
    {
        auto t = toks[p];
        if (t.kind != T.eof)
            p++;
        return t;
    }

    bool accept(T kind)
    {
        if (k == kind)
        {
            take();
            return true;
        }
        return false;
    }

    Token expect(T kind)
    {
        if (k != kind)
            throw parseError();
        return take();
    }

    CompileError parseError() const
    {
        return err(Kind.parse, pos);
    }

    // ------------------------------------------------------------ items

    Item parseItem()
    {
        bool pub = false;
        if (k == T.kwPub)
        {
            take();
            pub = true;
            if (k != T.kwFn && k != T.kwStruct && k != T.kwEnum && k != T.kwTrait)
                throw parseError();
        }
        switch (k)
        {
        case T.kwUse:
            return parseUse();
        case T.kwFn:
            return parseFn(pub, false, false);
        case T.kwStruct:
            return parseStruct(pub);
        case T.kwEnum:
            return parseEnum(pub);
        case T.kwTrait:
            return parseTrait(pub);
        case T.kwImpl:
            return parseImpl();
        default:
            throw parseError();
        }
    }

    UseItem parseUse()
    {
        auto u = new UseItem(take().pos);
        auto m = expect(T.ident);
        u.mod = m.id;
        u.modPos = m.pos;
        u.alias_ = m.id;
        u.aliasPos = m.pos;
        if (accept(T.kwAs))
        {
            auto a = expect(T.ident);
            u.alias_ = a.id;
            u.aliasPos = a.pos;
        }
        expect(T.semi);
        return u;
    }

    GenParam[] parseGenerics(bool allowBounds)
    {
        GenParam[] r;
        if (k != T.lt)
            return r;
        take();
        while (true)
        {
            auto id = expect(T.ident);
            GenParam g;
            g.name = id.id;
            g.pos = id.pos;
            if (k == T.colon)
            {
                if (!allowBounds)
                    throw parseError();
                take();
                g.bounds ~= parseTraitRef();
                while (accept(T.plus))
                    g.bounds ~= parseTraitRef();
            }
            r ~= g;
            if (accept(T.comma))
            {
                if (k == T.gt)
                    break;
                continue;
            }
            break;
        }
        expect(T.gt);
        return r;
    }

    TraitRef parseTraitRef()
    {
        TraitRef t;
        auto id = expect(T.ident);
        t.pos = id.pos;
        if (k == T.colonColon)
        {
            take();
            auto n = expect(T.ident);
            t.qual = id.id;
            t.qualPos = id.pos;
            t.name = n.id;
            t.namePos = n.pos;
        }
        else
        {
            t.name = id.id;
            t.namePos = id.pos;
        }
        return t;
    }

    Param parseParam()
    {
        auto id = expect(T.ident);
        expect(T.colon);
        return Param(id.id, id.pos, parseType());
    }

    /// A function (`isMethod == false`), a trait method or an impl method.
    FnDecl parseFn(bool pub, bool isMethod, bool inTrait)
    {
        auto f = new FnDecl(expect(T.kwFn).pos);
        f.pub = pub;
        auto name = expect(T.ident);
        f.name = name.id;
        f.namePos = name.pos;
        if (!isMethod)
            f.gparams = parseGenerics(true);
        expect(T.lparen);
        if (isMethod)
        {
            expect(T.kwSelf);
            f.hasSelf = true;
            if (accept(T.comma))
                parseParamList(f);
        }
        else if (k != T.rparen)
            parseParamList(f);
        expect(T.rparen);
        if (accept(T.arrow))
            f.ret = parseType();
        if (inTrait && k == T.semi)
            take();
        else
            f.body = parseBlock();
        return f;
    }

    void parseParamList(FnDecl f)
    {
        while (true)
        {
            f.params ~= parseParam();
            if (accept(T.comma))
            {
                if (k == T.rparen)
                    break;
                continue;
            }
            break;
        }
    }

    StructDecl parseStruct(bool pub)
    {
        auto s = new StructDecl(take().pos);
        s.pub = pub;
        auto name = expect(T.ident);
        s.name = name.id;
        s.namePos = name.pos;
        s.gparams = parseGenerics(false);
        expect(T.lbrace);
        while (k != T.rbrace)
        {
            auto id = expect(T.ident);
            expect(T.colon);
            s.fields ~= FieldDecl(id.id, id.pos, parseType());
            if (!accept(T.comma))
                break;
        }
        expect(T.rbrace);
        return s;
    }

    EnumDecl parseEnum(bool pub)
    {
        auto e = new EnumDecl(take().pos);
        e.pub = pub;
        auto name = expect(T.ident);
        e.name = name.id;
        e.namePos = name.pos;
        e.gparams = parseGenerics(false);
        expect(T.lbrace);
        while (k != T.rbrace)
        {
            auto id = expect(T.ident);
            VariantDecl v;
            v.name = id.id;
            v.pos = id.pos;
            if (accept(T.lparen))
            {
                while (true)
                {
                    v.payload ~= parseType();
                    if (accept(T.comma))
                    {
                        if (k == T.rparen)
                            break;
                        continue;
                    }
                    break;
                }
                expect(T.rparen);
            }
            e.variants ~= v;
            if (!accept(T.comma))
                break;
        }
        expect(T.rbrace);
        return e;
    }

    TraitDecl parseTrait(bool pub)
    {
        auto t = new TraitDecl(take().pos);
        t.pub = pub;
        auto name = expect(T.ident);
        t.name = name.id;
        t.namePos = name.pos;
        expect(T.lbrace);
        while (k != T.rbrace)
            t.methods ~= parseFn(false, true, true);
        expect(T.rbrace);
        return t;
    }

    ImplDecl parseImpl()
    {
        auto im = new ImplDecl(take().pos);
        im.gparams = parseGenerics(true);
        im.trait = parseTraitRef();
        expect(T.kwFor);
        im.head = parseType();
        expect(T.lbrace);
        while (k != T.rbrace)
            im.methods ~= parseFn(false, true, false);
        expect(T.rbrace);
        return im;
    }

    // ------------------------------------------------------------ types

    TypeExpr parseType()
    {
        auto t = new TypeExpr();
        t.pos = pos;
        switch (k)
        {
        case T.lbracket:
        {
            take();
            t.kind = TyK.list;
            auto saved = typeArgDepth;
            typeArgDepth = 0;
            t.args ~= parseType();
            noPending();
            expect(T.rbracket);
            typeArgDepth = saved;
            return t;
        }
        case T.hashBracket:
        {
            take();
            t.kind = TyK.map;
            auto saved = typeArgDepth;
            typeArgDepth = 0;
            t.args ~= parseType();
            noPending();
            expect(T.colon);
            t.args ~= parseType();
            noPending();
            expect(T.rbracket);
            typeArgDepth = saved;
            return t;
        }
        case T.lparen:
        {
            take();
            t.kind = TyK.tuple;
            auto saved = typeArgDepth;
            typeArgDepth = 0;
            t.args ~= parseType();
            noPending();
            expect(T.comma);
            while (k != T.rparen)
            {
                t.args ~= parseType();
                noPending();
                if (!accept(T.comma))
                    break;
            }
            expect(T.rparen);
            typeArgDepth = saved;
            return t;
        }
        case T.kwFn:
        {
            take();
            t.kind = TyK.fn;
            auto saved = typeArgDepth;
            typeArgDepth = 0;
            expect(T.lparen);
            while (k != T.rparen)
            {
                t.args ~= parseType();
                noPending();
                if (!accept(T.comma))
                    break;
            }
            expect(T.rparen);
            typeArgDepth = saved;
            if (accept(T.arrow))
                t.ret = parseType();
            return t;
        }
        case T.ident:
        {
            t.kind = TyK.path;
            auto id = take();
            if (k == T.colonColon)
            {
                take();
                auto n = expect(T.ident);
                t.qual = id.id;
                t.qualPos = id.pos;
                t.name = n.id;
                t.namePos = n.pos;
            }
            else
            {
                t.name = id.id;
                t.namePos = id.pos;
            }
            if (k == T.lt)
                parseTypeArgs(t);
            return t;
        }
        default:
            throw parseError();
        }
    }

    void noPending()
    {
        if (pendingGt)
            throw parseError();
    }

    void parseTypeArgs(TypeExpr t)
    {
        expect(T.lt);
        typeArgDepth++;
        while (true)
        {
            t.args ~= parseType();
            if (pendingGt)
            {
                pendingGt = false;
                typeArgDepth--;
                return;
            }
            if (k == T.comma)
            {
                take();
                if (k != T.gt && k != T.shr)
                    continue;
            }
            if (k == T.gt)
            {
                take();
                typeArgDepth--;
                return;
            }
            if (k == T.shr && typeArgDepth >= 2)
            {
                take();
                pendingGt = true;
                typeArgDepth--;
                return;
            }
            throw parseError();
        }
    }

    // ------------------------------------------------------------ blocks and statements

    BlockExpr parseBlock()
    {
        auto b = new BlockExpr(expect(T.lbrace).pos);
        while (k != T.rbrace)
        {
            switch (k)
            {
            case T.kwLet:
                b.stmts ~= parseLet();
                break;
            case T.kwVar:
                b.stmts ~= parseVar();
                break;
            case T.kwReturn:
            {
                auto s = new Stmt(SK.return_, take().pos);
                if (k != T.semi)
                    s.expr = parseExpr();
                expect(T.semi);
                b.stmts ~= s;
                break;
            }
            case T.kwWhile:
            {
                auto s = new Stmt(SK.while_, take().pos);
                s.expr = parseExpr();
                s.body = parseBlock();
                b.stmts ~= s;
                break;
            }
            case T.kwFor:
                b.stmts ~= parseFor();
                break;
            case T.kwBreak:
            {
                auto s = new Stmt(SK.break_, take().pos);
                expect(T.semi);
                b.stmts ~= s;
                break;
            }
            case T.kwContinue:
            {
                auto s = new Stmt(SK.continue_, take().pos);
                expect(T.semi);
                b.stmts ~= s;
                break;
            }
            default:
            {
                auto e = parseExpr();
                if (k == T.eq)
                {
                    take();
                    auto s = new Stmt(SK.assign, e.pos);
                    s.target = e;
                    s.expr = parseExpr();
                    expect(T.semi);
                    b.stmts ~= s;
                }
                else if (k == T.semi)
                {
                    take();
                    auto s = new Stmt(SK.expr, e.pos);
                    s.expr = e;
                    b.stmts ~= s;
                }
                else if (k == T.rbrace)
                {
                    b.tail = e;
                }
                else if (e.kind == EK.if_ || e.kind == EK.match)
                {
                    auto s = new Stmt(SK.expr, e.pos);
                    s.expr = e;
                    b.stmts ~= s;
                }
                else
                    throw parseError();
            }
            }
        }
        expect(T.rbrace);
        return b;
    }

    Stmt parseLet()
    {
        auto s = new Stmt(SK.let_, take().pos);
        s.pat = parsePattern();
        if (accept(T.colon))
            s.ann = parseType();
        expect(T.eq);
        s.expr = parseExpr();
        expect(T.semi);
        return s;
    }

    Stmt parseVar()
    {
        auto s = new Stmt(SK.var_, take().pos);
        auto id = expect(T.ident);
        s.name = id.id;
        s.namePos = id.pos;
        if (accept(T.colon))
            s.ann = parseType();
        expect(T.eq);
        s.expr = parseExpr();
        expect(T.semi);
        return s;
    }

    Stmt parseFor()
    {
        auto s = new Stmt(SK.for_, take().pos);
        s.pat = parsePattern();
        expect(T.kwIn);
        s.expr = parseExpr();
        if (accept(T.dotDot))
            s.hi = parseExpr();
        s.body = parseBlock();
        return s;
    }

    // ------------------------------------------------------------ patterns

    Pattern parsePattern()
    {
        auto pt = new Pattern();
        pt.pos = pos;
        switch (k)
        {
        case T.underscore:
            take();
            pt.kind = PatK.wild;
            return pt;
        case T.int_:
            pt.kind = PatK.int_;
            pt.ival = take().ival;
            return pt;
        case T.float_:
            pt.kind = PatK.float_;
            pt.fval = take().fval;
            return pt;
        case T.minus:
            take();
            if (k == T.int_)
            {
                pt.kind = PatK.int_;
                pt.ival = -take().ival;
            }
            else if (k == T.float_)
            {
                pt.kind = PatK.float_;
                pt.fval = -take().fval;
            }
            else
                throw parseError();
            return pt;
        case T.str:
            pt.kind = PatK.str;
            pt.sval = take().sval;
            return pt;
        case T.char_:
            pt.kind = PatK.char_;
            pt.ival = take().ival;
            return pt;
        case T.kwTrue:
        case T.kwFalse:
            pt.kind = PatK.bool_;
            pt.ival = take().kind == T.kwTrue ? 1 : 0;
            return pt;
        case T.lparen:
            take();
            pt.kind = PatK.tuple;
            pt.subs ~= parsePattern();
            expect(T.comma);
            while (k != T.rparen)
            {
                pt.subs ~= parsePattern();
                if (!accept(T.comma))
                    break;
            }
            expect(T.rparen);
            return pt;
        case T.lbracket:
            take();
            pt.kind = PatK.list;
            while (k != T.rbracket)
            {
                if (k == T.dotDot)
                {
                    take();
                    pt.hasRest = true;
                    if (k == T.ident)
                    {
                        auto id = take();
                        pt.restName = id.id;
                        pt.restPos = id.pos;
                    }
                    break;
                }
                pt.subs ~= parsePattern();
                if (!accept(T.comma))
                    break;
            }
            expect(T.rbracket);
            return pt;
        case T.ident:
        {
            auto id = take();
            if (k == T.colonColon)
            {
                take();
                auto n = expect(T.ident);
                pt.qual = id.id;
                pt.qualPos = id.pos;
                pt.cname = n.id;
                pt.cnamePos = n.pos;
            }
            else
            {
                pt.cname = id.id;
                pt.cnamePos = id.pos;
            }
            if (k == T.dot && kAt(1) == T.lbrace)
            {
                take();
                take();
                pt.kind = PatK.struct_;
                while (k != T.rbrace)
                {
                    if (k == T.dotDot)
                    {
                        take();
                        pt.structRest = true;
                        break;
                    }
                    auto f = expect(T.ident);
                    FieldPat fp;
                    fp.name = f.id;
                    fp.pos = f.pos;
                    if (accept(T.colon))
                        fp.pat = parsePattern();
                    pt.fields ~= fp;
                    if (!accept(T.comma))
                        break;
                }
                expect(T.rbrace);
                return pt;
            }
            if (k == T.lparen)
            {
                take();
                pt.kind = PatK.variant;
                pt.hasParens = true;
                while (true)
                {
                    pt.subs ~= parsePattern();
                    if (accept(T.comma))
                    {
                        if (k == T.rparen)
                            break;
                        continue;
                    }
                    break;
                }
                expect(T.rparen);
                return pt;
            }
            if (pt.qual.length == 0)
            {
                pt.kind = PatK.bind;
                pt.name = pt.cname;
            }
            else
                pt.kind = PatK.variant;
            return pt;
        }
        default:
            throw parseError();
        }
    }

    // ------------------------------------------------------------ expressions

    Expr parseExpr()
    {
        return parseBinary(1);
    }

    /// Binding power of a binary operator token (0 if it is not one).
    static int prec(T t)
    {
        switch (t)
        {
        case T.orOr:
            return 1;
        case T.andAnd:
            return 2;
        case T.eqEq, T.ne, T.lt, T.le, T.gt, T.ge:
            return 3;
        case T.pipe:
            return 4;
        case T.caret:
            return 5;
        case T.amp:
            return 6;
        case T.shl, T.shr:
            return 7;
        case T.plus, T.minus, T.plusPlus:
            return 8;
        case T.star, T.slash, T.percent:
            return 9;
        default:
            return 0;
        }
    }

    static Operator binOp(T t)
    {
        switch (t)
        {
        case T.orOr: return Operator.or;
        case T.andAnd: return Operator.and;
        case T.eqEq: return Operator.eq;
        case T.ne: return Operator.ne;
        case T.lt: return Operator.lt;
        case T.le: return Operator.le;
        case T.gt: return Operator.gt;
        case T.ge: return Operator.ge;
        case T.pipe: return Operator.bor;
        case T.caret: return Operator.bxor;
        case T.amp: return Operator.band;
        case T.shl: return Operator.shl;
        case T.shr: return Operator.shr;
        case T.plus: return Operator.add;
        case T.minus: return Operator.sub;
        case T.plusPlus: return Operator.concat;
        case T.star: return Operator.mul;
        case T.slash: return Operator.div;
        default: return Operator.rem;
        }
    }

    /// Precedence climbing; comparison (level 3) is non-associative.
    Expr parseBinary(int minPrec)
    {
        auto left = parseUnary();
        bool afterCmp = false;
        while (true)
        {
            const pr = prec(k);
            if (pr == 0 || pr < minPrec || (pr == 3 && afterCmp))
                return left; // a second comparison is left for the caller to reject
            const opTok = take();
            auto right = parseBinary(pr + 1);
            auto b = new BinaryExpr(left.pos, binOp(opTok.kind), left, right);
            b.opPos = opTok.pos;
            left = b;
            afterCmp = pr == 3;
        }
    }

    Expr parseUnary()
    {
        Operator op;
        switch (k)
        {
        case T.minus:
            op = Operator.neg;
            break;
        case T.bang:
            op = Operator.not;
            break;
        case T.tilde:
            op = Operator.bnot;
            break;
        default:
            return parsePostfix();
        }
        const t = take();
        return new UnaryExpr(t.pos, op, parseUnary());
    }

    Expr[] parseArgs(T close)
    {
        Expr[] args;
        while (k != close)
        {
            args ~= parseExpr();
            if (!accept(T.comma))
                break;
        }
        expect(close);
        return args;
    }

    Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (true)
        {
            switch (k)
            {
            case T.lparen:
                take();
                e = new CallExpr(e.pos, e, parseArgs(T.rparen));
                break;
            case T.lbracket:
            {
                take();
                auto i = parseExpr();
                expect(T.rbracket);
                e = new IndexExpr(e.pos, e, i);
                break;
            }
            case T.dot:
            {
                take();
                auto id = expect(T.ident);
                if (k == T.lparen)
                {
                    take();
                    e = new MethodExpr(e.pos, e, id.id, id.pos, parseArgs(T.rparen));
                }
                else
                    e = new FieldExpr(e.pos, e, id.id, id.pos);
                break;
            }
            default:
                return e;
            }
        }
    }

    Expr parsePrimary()
    {
        const pos0 = pos;
        switch (k)
        {
        case T.int_:
        {
            auto l = new LitExpr(EK.int_, pos0);
            l.ival = take().ival;
            return l;
        }
        case T.float_:
        {
            auto l = new LitExpr(EK.float_, pos0);
            l.fval = take().fval;
            return l;
        }
        case T.str:
        {
            auto l = new LitExpr(EK.str, pos0);
            l.sval = take().sval;
            return l;
        }
        case T.char_:
        {
            auto l = new LitExpr(EK.char_, pos0);
            l.ival = take().ival;
            return l;
        }
        case T.kwTrue:
        case T.kwFalse:
        {
            auto l = new LitExpr(EK.bool_, pos0);
            l.ival = take().kind == T.kwTrue ? 1 : 0;
            return l;
        }
        case T.kwSelf:
            take();
            return new SelfExpr(pos0);
        case T.lparen:
        {
            take();
            auto first = parseExpr();
            if (k == T.comma)
            {
                auto t = new SeqExpr(EK.tuple, pos0);
                t.elems ~= first;
                while (accept(T.comma))
                {
                    if (k == T.rparen && t.elems.length >= 2)
                        break;
                    t.elems ~= parseExpr();
                }
                expect(T.rparen);
                return t;
            }
            expect(T.rparen);
            return first;
        }
        case T.lbracket:
        {
            take();
            auto l = new SeqExpr(EK.list, pos0);
            l.elems = parseArgs(T.rbracket);
            return l;
        }
        case T.hashBracket:
        {
            take();
            auto m = new SeqExpr(EK.map, pos0);
            while (k != T.rbracket)
            {
                m.elems ~= parseExpr();
                expect(T.colon);
                m.elems ~= parseExpr();
                if (!accept(T.comma))
                    break;
            }
            expect(T.rbracket);
            return m;
        }
        case T.pipe:
        case T.orOr:
            return parseLambda();
        case T.kwIf:
            return parseIf();
        case T.kwMatch:
            return parseMatch();
        case T.ident:
            return parsePathOrStruct();
        default:
            throw parseError();
        }
    }

    Expr parsePathOrStruct()
    {
        const pos0 = pos;
        auto id = take();
        string qual, name = id.id;
        Pos qualPos, namePos = id.pos;
        if (k == T.colonColon)
        {
            take();
            auto n = expect(T.ident);
            qual = id.id;
            qualPos = id.pos;
            name = n.id;
            namePos = n.pos;
        }
        if (k == T.dot && kAt(1) == T.lbrace)
        {
            take();
            take();
            auto s = new StructLitExpr(pos0);
            s.qual = qual;
            s.qualPos = qualPos;
            s.name = name;
            s.namePos = namePos;
            while (k != T.rbrace)
            {
                auto f = expect(T.ident);
                expect(T.colon);
                s.inits ~= FieldInit(f.id, f.pos, parseExpr());
                if (!accept(T.comma))
                    break;
            }
            expect(T.rbrace);
            return s;
        }
        auto pe = new PathExpr(pos0);
        pe.qual = qual;
        pe.qualPos = qualPos;
        pe.name = name;
        pe.namePos = namePos;
        return pe;
    }

    Expr parseLambda()
    {
        auto lam = new LambdaExpr(pos);
        if (k == T.orOr)
            take();
        else
        {
            take();
            while (true)
            {
                auto id = expect(T.ident);
                LParam lp;
                lp.name = id.id;
                lp.pos = id.pos;
                if (accept(T.colon))
                    lp.ann = parseType();
                lam.params ~= lp;
                if (accept(T.comma))
                {
                    if (k == T.pipe)
                        break;
                    continue;
                }
                break;
            }
            expect(T.pipe);
        }
        if (accept(T.arrow))
            lam.retAnn = parseType();
        if (k == T.lbrace)
            lam.body = parseBlock();
        else
            lam.body = parseExpr();
        return lam;
    }

    Expr parseIf()
    {
        auto e = new IfExpr(take().pos);
        e.cond = parseExpr();
        e.then = parseBlock();
        if (accept(T.kwElse))
        {
            if (k == T.kwIf)
                e.else_ = parseIf();
            else
                e.else_ = parseBlock();
        }
        return e;
    }

    Expr parseMatch()
    {
        auto m = new MatchExpr(take().pos);
        m.scrut = parseExpr();
        expect(T.lbrace);
        while (k != T.rbrace)
        {
            Arm a;
            a.pat = parsePattern();
            if (accept(T.kwWhen))
                a.guard = parseExpr();
            expect(T.arrow);
            bool block = false;
            if (k == T.lbrace)
            {
                a.body = parseBlock();
                block = true;
            }
            else
                a.body = parseExpr();
            m.arms ~= a;
            if (!accept(T.comma) && k != T.rbrace && !block)
                throw parseError();
        }
        expect(T.rbrace);
        return m;
    }
}

version (unittest)
{
    private Item[] parseSrc(string src)
    {
        import langvm.source : SourceModule, decodeUtf8, splitLines;

        return parseModule(lex(SourceModule("t", splitLines(decodeUtf8(src)))));
    }

    private Pos parseFailure(string src)
    {
        try
            parseSrc(src);
        catch (CompileError e)
        {
            assert(e.kind == Kind.parse);
            return e.pos;
        }
        assert(false, "expected a parse error");
    }
}

unittest
{
    auto items = parseSrc(`
        use util as u;
        pub struct P<A, B> { a: A, b: [B], }
        enum E { X, Y(Int, Str), }
        trait T { fn f(self) -> Int; fn g(self, x: Int) { } }
        impl<A: T + Eq> T for [A] { fn f(self) -> Int { 1 } }
        fn main() { let x: Option<Option<Int>> = None; }
    `);
    assert(items.length == 6);
    assert(items[0].kind == IK.use);
    assert(items[5].kind == IK.fn);
}

unittest
{
    // a `>>` closes two argument lists, but never splits otherwise
    parseSrc("fn f(x: A<B<C>>) {}");
    parseSrc("fn f(x: A<B<C<D>>>) {}");
    assert(parseFailure("fn f(x: A<B>>) {}") == Pos(1, 12));
    assert(parseFailure("fn f(x: [A<B>>]) {}").line == 1);
}

unittest
{
    // comparison is non-associative; an if statement continues as a call
    assert(parseFailure("fn f() { a < b < c; }") == Pos(1, 16));
    parseSrc("fn f() { if c { 1 } else { 2 } (1, 2); }");
    assert(parseFailure("fn f() { | | 8 }") == Pos(1, 12));
    assert(parseFailure("fn f(") == Pos(1, 6));
}
