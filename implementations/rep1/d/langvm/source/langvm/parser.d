/// Recursive-descent parser producing the AST of a module.
module langvm.parser;

import langvm.ast;
import langvm.diag;
import langvm.lexer;
import langvm.model;

/// Parses the token array of one module.
struct Parser
{
    private Token[] toks;
    private size_t p;

    /// Parses a whole module body.
    /// Throws: [CompileError] (`parse`).
    static ModuleAst parseModule(string name, Token[] tokens)
    {
        Parser ps;
        ps.toks = tokens;
        auto m = new ModuleAst;
        m.name = name;
        while (ps.kind != Tk.eof)
            m.items ~= ps.parseItem();
        return m;
    }

    /// Parses a function signature `name<T: B>(a: A, ...) -> R` (no body); used for built-ins.
    static FnItem parseSignature(Token[] tokens)
    {
        Parser ps;
        ps.toks = tokens;
        auto f = new FnItem;
        f.pos = ps.cur.pos;
        f.namePos = ps.cur.pos;
        f.name = ps.expectIdent();
        if (ps.kind == Tk.lt)
            f.gen = ps.parseGenerics(true);
        ps.expect(Tk.lParen);
        if (ps.kind != Tk.rParen)
            f.params = ps.parseParams();
        ps.expect(Tk.rParen);
        if (ps.accept(Tk.arrow))
            f.ret = ps.parseType();
        ps.expect(Tk.eof);
        return f;
    }

    // ------------------------------------------------------------ token helpers

    private ref Token cur()
    {
        return toks[p];
    }

    private Tk kind()
    {
        return toks[p].kind;
    }

    private Tk kindAt(size_t off)
    {
        size_t q = p + off;
        return q < toks.length ? toks[q].kind : Tk.eof;
    }

    private noreturn err()
    {
        fail("parse", toks[p].pos);
    }

    private Token advance()
    {
        auto t = toks[p];
        if (p + 1 < toks.length)
            p++;
        return t;
    }

    private bool accept(Tk k)
    {
        if (kind == k)
        {
            advance();
            return true;
        }
        return false;
    }

    private Token expect(Tk k)
    {
        if (kind != k)
            err();
        return advance();
    }

    private string expectIdent()
    {
        if (kind != Tk.ident)
            err();
        return advance().text;
    }

    // ------------------------------------------------------------ items

    private Item parseItem()
    {
        bool pub = false;
        Pos startPos = cur.pos;
        if (kind == Tk.kwPub)
        {
            pub = true;
            advance();
            if (kind != Tk.kwFn && kind != Tk.kwStruct && kind != Tk.kwEnum && kind != Tk.kwTrait)
                err();
        }
        Item it;
        switch (kind)
        {
        case Tk.kwUse:
            it = parseUse();
            break;
        case Tk.kwFn:
            it = parseFn();
            break;
        case Tk.kwStruct:
            it = parseStruct();
            break;
        case Tk.kwEnum:
            it = parseEnum();
            break;
        case Tk.kwTrait:
            it = parseTrait();
            break;
        case Tk.kwImpl:
            it = parseImpl();
            break;
        default:
            err();
        }
        it.pub = pub;
        return it;
    }

    private UseItem parseUse()
    {
        auto u = new UseItem;
        u.pos = advance().pos;
        u.modPos = cur.pos;
        u.mod = expectIdent();
        if (accept(Tk.kwAs))
        {
            u.hasAlias = true;
            u.aliasPos = cur.pos;
            u.alias_ = expectIdent();
        }
        expect(Tk.semi);
        return u;
    }

    private GenParamAst[] parseGenerics(bool allowBounds)
    {
        GenParamAst[] r;
        expect(Tk.lt);
        while (true)
        {
            auto g = new GenParamAst;
            g.pos = cur.pos;
            g.name = expectIdent();
            if (kind == Tk.colon)
            {
                if (!allowBounds)
                    err();
                advance();
                g.bounds ~= parseTraitRef();
                while (accept(Tk.plus))
                    g.bounds ~= parseTraitRef();
            }
            r ~= g;
            if (accept(Tk.comma))
            {
                if (kind == Tk.gt)
                    break;
                continue;
            }
            break;
        }
        expect(Tk.gt);
        return r;
    }

    private TraitRefAst parseTraitRef()
    {
        auto t = new TraitRefAst;
        t.pos = cur.pos;
        t.namePos = cur.pos;
        t.name = expectIdent();
        if (accept(Tk.colonColon))
        {
            t.qual = t.name;
            t.qualPos = t.namePos;
            t.namePos = cur.pos;
            t.name = expectIdent();
        }
        return t;
    }

    private ParamAst[] parseParams()
    {
        ParamAst[] r;
        while (true)
        {
            ParamAst a;
            a.pos = cur.pos;
            a.name = expectIdent();
            expect(Tk.colon);
            a.te = parseType();
            r ~= a;
            if (accept(Tk.comma))
            {
                if (kind == Tk.rParen)
                    break;
                continue;
            }
            break;
        }
        return r;
    }

    private FnItem parseFn()
    {
        auto f = new FnItem;
        f.pos = advance().pos;
        f.namePos = cur.pos;
        f.name = expectIdent();
        if (kind == Tk.lt)
            f.gen = parseGenerics(true);
        expect(Tk.lParen);
        if (kind != Tk.rParen)
            f.params = parseParams();
        expect(Tk.rParen);
        if (accept(Tk.arrow))
            f.ret = parseType();
        f.body = parseBlock();
        return f;
    }

    private StructItem parseStruct()
    {
        auto s = new StructItem;
        s.pos = advance().pos;
        s.namePos = cur.pos;
        s.name = expectIdent();
        if (kind == Tk.lt)
            s.gen = parseGenerics(false);
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
        {
            ParamAst a;
            a.pos = cur.pos;
            a.name = expectIdent();
            expect(Tk.colon);
            a.te = parseType();
            s.fields ~= a;
            if (!accept(Tk.comma))
                break;
        }
        expect(Tk.rBrace);
        return s;
    }

    private EnumItem parseEnum()
    {
        auto e = new EnumItem;
        e.pos = advance().pos;
        e.namePos = cur.pos;
        e.name = expectIdent();
        if (kind == Tk.lt)
            e.gen = parseGenerics(false);
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
        {
            auto v = new VariantAst;
            v.pos = cur.pos;
            v.name = expectIdent();
            if (accept(Tk.lParen))
            {
                while (true)
                {
                    v.payload ~= parseType();
                    if (accept(Tk.comma))
                    {
                        if (kind == Tk.rParen)
                            break;
                        continue;
                    }
                    break;
                }
                expect(Tk.rParen);
            }
            e.variants ~= v;
            if (!accept(Tk.comma))
                break;
        }
        expect(Tk.rBrace);
        return e;
    }

    private MethodAst parseMethod(bool allowNoBody)
    {
        auto m = new MethodAst;
        m.pos = expect(Tk.kwFn).pos;
        m.namePos = cur.pos;
        m.name = expectIdent();
        expect(Tk.lParen);
        expect(Tk.kwSelf);
        if (accept(Tk.comma))
            m.params = parseParams();
        expect(Tk.rParen);
        if (accept(Tk.arrow))
            m.ret = parseType();
        if (allowNoBody && accept(Tk.semi))
            return m;
        m.body = parseBlock();
        return m;
    }

    private TraitItem parseTrait()
    {
        auto t = new TraitItem;
        t.pos = advance().pos;
        t.namePos = cur.pos;
        t.name = expectIdent();
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
            t.methods ~= parseMethod(true);
        expect(Tk.rBrace);
        return t;
    }

    private ImplAst parseImpl()
    {
        auto im = new ImplAst;
        im.pos = advance().pos;
        if (kind == Tk.lt)
            im.gen = parseGenerics(true);
        im.trait = parseTraitRef();
        expect(Tk.kwFor);
        im.head = parseType();
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
            im.methods ~= parseMethod(false);
        expect(Tk.rBrace);
        return im;
    }

    // ------------------------------------------------------------ types

    private TypeExpr parseType()
    {
        auto t = new TypeExpr;
        t.pos = cur.pos;
        switch (kind)
        {
        case Tk.lBracket:
            advance();
            t.kind = TypeExpr.Kind.list;
            t.args = [parseType()];
            expect(Tk.rBracket);
            return t;
        case Tk.hashBracket:
            advance();
            t.kind = TypeExpr.Kind.map;
            auto k = parseType();
            expect(Tk.colon);
            auto v = parseType();
            t.args = [k, v];
            expect(Tk.rBracket);
            return t;
        case Tk.lParen:
            advance();
            t.kind = TypeExpr.Kind.tuple;
            t.args ~= parseType();
            expect(Tk.comma);
            while (true)
            {
                t.args ~= parseType();
                if (accept(Tk.comma))
                {
                    if (kind == Tk.rParen)
                        break;
                    continue;
                }
                break;
            }
            expect(Tk.rParen);
            return t;
        case Tk.kwFn:
            advance();
            t.kind = TypeExpr.Kind.fn;
            expect(Tk.lParen);
            if (kind != Tk.rParen)
            {
                while (true)
                {
                    t.args ~= parseType();
                    if (accept(Tk.comma))
                    {
                        if (kind == Tk.rParen)
                            break;
                        continue;
                    }
                    break;
                }
            }
            expect(Tk.rParen);
            if (accept(Tk.arrow))
                t.ret = parseType();
            return t;
        case Tk.ident:
            t.kind = TypeExpr.Kind.path;
            t.namePos = cur.pos;
            t.name = advance().text;
            if (accept(Tk.colonColon))
            {
                t.qual = t.name;
                t.qualPos = t.namePos;
                t.namePos = cur.pos;
                t.name = expectIdent();
            }
            if (kind == Tk.lt)
            {
                advance();
                t.hasArgs = true;
                while (true)
                {
                    t.args ~= parseType();
                    if (accept(Tk.comma))
                    {
                        if (kind == Tk.gt || kind == Tk.shr)
                            break;
                        continue;
                    }
                    break;
                }
                closeAngle();
            }
            return t;
        default:
            err();
        }
    }

    /// Consumes one `>`; a `>>` token closes two lists, so it is rewritten to `>` and kept.
    private void closeAngle()
    {
        if (kind == Tk.gt)
            advance();
        else if (kind == Tk.shr)
        {
            toks[p].kind = Tk.gt;
            toks[p].pos.col += 1;
        }
        else
            err();
    }

    // ------------------------------------------------------------ statements

    private Block parseBlock()
    {
        auto b = new Block;
        b.pos = cur.pos;
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
        {
            Pos sp = cur.pos;
            switch (kind)
            {
            case Tk.kwLet:
            {
                advance();
                auto s = new LetStmt;
                s.pos = sp;
                s.pat = parsePattern();
                if (accept(Tk.colon))
                    s.te = parseType();
                expect(Tk.assign);
                s.init = parseExpr();
                expect(Tk.semi);
                b.stmts ~= s;
                break;
            }
            case Tk.kwVar:
            {
                advance();
                auto s = new VarStmt;
                s.pos = sp;
                s.namePos = cur.pos;
                s.name = expectIdent();
                if (accept(Tk.colon))
                    s.te = parseType();
                expect(Tk.assign);
                s.init = parseExpr();
                expect(Tk.semi);
                b.stmts ~= s;
                break;
            }
            case Tk.kwReturn:
            {
                advance();
                auto s = new ReturnStmt;
                s.pos = sp;
                if (kind != Tk.semi)
                    s.value = parseExpr();
                expect(Tk.semi);
                b.stmts ~= s;
                break;
            }
            case Tk.kwWhile:
            {
                advance();
                auto s = new WhileStmt;
                s.pos = sp;
                s.cond = parseExpr();
                s.body = parseBlock();
                b.stmts ~= s;
                break;
            }
            case Tk.kwFor:
            {
                advance();
                auto s = new ForStmt;
                s.pos = sp;
                s.pat = parsePattern();
                expect(Tk.kwIn);
                s.iter = parseExpr();
                if (accept(Tk.dotDot))
                    s.hi = parseExpr();
                s.body = parseBlock();
                b.stmts ~= s;
                break;
            }
            case Tk.kwBreak:
            {
                advance();
                auto s = new BreakStmt;
                s.pos = sp;
                expect(Tk.semi);
                b.stmts ~= s;
                break;
            }
            case Tk.kwContinue:
            {
                advance();
                auto s = new ContinueStmt;
                s.pos = sp;
                expect(Tk.semi);
                b.stmts ~= s;
                break;
            }
            default:
            {
                auto e = parseExpr();
                if (kind == Tk.assign)
                {
                    advance();
                    auto s = new AssignStmt;
                    s.pos = e.pos;
                    s.target = e;
                    s.value = parseExpr();
                    expect(Tk.semi);
                    b.stmts ~= s;
                }
                else if (kind == Tk.semi)
                {
                    advance();
                    auto s = new ExprStmt;
                    s.pos = e.pos;
                    s.e = e;
                    b.stmts ~= s;
                }
                else if (kind == Tk.rBrace)
                {
                    b.trailing = e;
                }
                else if (cast(IfExpr) e !is null || cast(MatchExpr) e !is null)
                {
                    auto s = new ExprStmt;
                    s.pos = e.pos;
                    s.e = e;
                    b.stmts ~= s;
                }
                else
                    err();
                break;
            }
            }
        }
        expect(Tk.rBrace);
        return b;
    }

    // ------------------------------------------------------------ expressions

    /// Parses an expression.
    Expr parseExpr()
    {
        return parseOr();
    }

    private Expr bin(Tk op, Expr l, Expr r, Pos opPos)
    {
        auto b = new Binary;
        b.pos = l.pos;
        b.op = op;
        b.l = l;
        b.r = r;
        b.opPos = opPos;
        return b;
    }

    private Expr parseOr()
    {
        auto l = parseAnd();
        while (kind == Tk.orOr)
        {
            Pos op = advance().pos;
            l = bin(Tk.orOr, l, parseAnd(), op);
        }
        return l;
    }

    private Expr parseAnd()
    {
        auto l = parseCmp();
        while (kind == Tk.andAnd)
        {
            Pos op = advance().pos;
            l = bin(Tk.andAnd, l, parseCmp(), op);
        }
        return l;
    }

    private Expr parseCmp()
    {
        auto l = parseBitOr();
        switch (kind)
        {
        case Tk.eqEq, Tk.notEq, Tk.lt, Tk.ltEq, Tk.gt, Tk.gtEq:
            auto t = advance();
            return bin(t.kind, l, parseBitOr(), t.pos);
        default:
            return l;
        }
    }

    private Expr parseBitOr()
    {
        auto l = parseBitXor();
        while (kind == Tk.pipe)
        {
            Pos op = advance().pos;
            l = bin(Tk.pipe, l, parseBitXor(), op);
        }
        return l;
    }

    private Expr parseBitXor()
    {
        auto l = parseBitAnd();
        while (kind == Tk.caret)
        {
            Pos op = advance().pos;
            l = bin(Tk.caret, l, parseBitAnd(), op);
        }
        return l;
    }

    private Expr parseBitAnd()
    {
        auto l = parseShift();
        while (kind == Tk.amp)
        {
            Pos op = advance().pos;
            l = bin(Tk.amp, l, parseShift(), op);
        }
        return l;
    }

    private Expr parseShift()
    {
        auto l = parseAdd();
        while (kind == Tk.shl || kind == Tk.shr)
        {
            auto t = advance();
            l = bin(t.kind, l, parseAdd(), t.pos);
        }
        return l;
    }

    private Expr parseAdd()
    {
        auto l = parseMul();
        while (kind == Tk.plus || kind == Tk.minus || kind == Tk.plusPlus)
        {
            auto t = advance();
            l = bin(t.kind, l, parseMul(), t.pos);
        }
        return l;
    }

    private Expr parseMul()
    {
        auto l = parseUnary();
        while (kind == Tk.star || kind == Tk.slash || kind == Tk.percent)
        {
            auto t = advance();
            l = bin(t.kind, l, parseUnary(), t.pos);
        }
        return l;
    }

    private Expr parseUnary()
    {
        if (kind == Tk.minus || kind == Tk.bang || kind == Tk.tilde)
        {
            auto t = advance();
            auto u = new Unary;
            u.pos = t.pos;
            u.op = t.kind;
            u.e = parseUnary();
            return u;
        }
        return parsePostfix();
    }

    private Expr[] parseArgs(Tk close)
    {
        Expr[] args;
        if (kind != close)
        {
            while (true)
            {
                args ~= parseExpr();
                if (accept(Tk.comma))
                {
                    if (kind == close)
                        break;
                    continue;
                }
                break;
            }
        }
        expect(close);
        return args;
    }

    private Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (true)
        {
            if (kind == Tk.lParen)
            {
                advance();
                auto c = new Call;
                c.pos = e.pos;
                c.callee = e;
                c.args = parseArgs(Tk.rParen);
                e = c;
            }
            else if (kind == Tk.lBracket)
            {
                advance();
                auto ix = new IndexExpr;
                ix.pos = e.pos;
                ix.base = e;
                ix.index = parseExpr();
                expect(Tk.rBracket);
                e = ix;
            }
            else if (kind == Tk.dot)
            {
                advance();
                Pos np = cur.pos;
                string n = expectIdent();
                if (kind == Tk.lParen)
                {
                    advance();
                    auto m = new MethodCall;
                    m.pos = e.pos;
                    m.recv = e;
                    m.name = n;
                    m.namePos = np;
                    m.args = parseArgs(Tk.rParen);
                    e = m;
                }
                else
                {
                    auto f = new FieldExpr;
                    f.pos = e.pos;
                    f.base = e;
                    f.name = n;
                    f.namePos = np;
                    e = f;
                }
            }
            else
                break;
        }
        return e;
    }

    private Expr parsePrimary()
    {
        auto t = cur;
        switch (t.kind)
        {
        case Tk.intLit:
        {
            advance();
            auto e = new IntLit;
            e.pos = t.pos;
            e.v = t.ival;
            return e;
        }
        case Tk.floatLit:
        {
            advance();
            auto e = new FloatLit;
            e.pos = t.pos;
            e.v = t.fval;
            return e;
        }
        case Tk.strLit:
        {
            advance();
            auto e = new StrLit;
            e.pos = t.pos;
            e.v = t.sval;
            return e;
        }
        case Tk.charLit:
        {
            advance();
            auto e = new CharLit;
            e.pos = t.pos;
            e.v = cast(dchar) t.ival;
            return e;
        }
        case Tk.kwTrue, Tk.kwFalse:
        {
            advance();
            auto e = new BoolLit;
            e.pos = t.pos;
            e.v = t.kind == Tk.kwTrue;
            return e;
        }
        case Tk.kwSelf:
        {
            advance();
            auto e = new SelfExpr;
            e.pos = t.pos;
            return e;
        }
        case Tk.lParen:
        {
            advance();
            auto first = parseExpr();
            if (accept(Tk.rParen))
                return first;
            auto tl = new TupleLit;
            tl.pos = t.pos;
            tl.elems ~= first;
            expect(Tk.comma);
            while (true)
            {
                tl.elems ~= parseExpr();
                if (accept(Tk.comma))
                {
                    if (kind == Tk.rParen)
                        break;
                    continue;
                }
                break;
            }
            expect(Tk.rParen);
            return tl;
        }
        case Tk.lBracket:
        {
            advance();
            auto l = new ListLit;
            l.pos = t.pos;
            l.elems = parseArgs(Tk.rBracket);
            return l;
        }
        case Tk.hashBracket:
        {
            advance();
            auto m = new MapLit;
            m.pos = t.pos;
            if (kind != Tk.rBracket)
            {
                while (true)
                {
                    m.keys ~= parseExpr();
                    expect(Tk.colon);
                    m.vals ~= parseExpr();
                    if (accept(Tk.comma))
                    {
                        if (kind == Tk.rBracket)
                            break;
                        continue;
                    }
                    break;
                }
            }
            expect(Tk.rBracket);
            return m;
        }
        case Tk.pipe, Tk.orOr:
            return parseLambda();
        case Tk.kwIf:
            return parseIf();
        case Tk.kwMatch:
            return parseMatch();
        case Tk.ident:
        {
            advance();
            string first = t.text;
            Pos firstPos = t.pos;
            string qual;
            Pos qualPos;
            string name = first;
            Pos namePos = firstPos;
            if (accept(Tk.colonColon))
            {
                qual = first;
                qualPos = firstPos;
                namePos = cur.pos;
                name = expectIdent();
            }
            if (kind == Tk.dot && kindAt(1) == Tk.lBrace)
            {
                advance();
                advance();
                auto s = new StructLit;
                s.pos = firstPos;
                s.qual = qual;
                s.qualPos = qualPos;
                s.name = name;
                s.namePos = namePos;
                if (kind != Tk.rBrace)
                {
                    while (true)
                    {
                        FieldInit fi;
                        fi.pos = cur.pos;
                        fi.name = expectIdent();
                        expect(Tk.colon);
                        fi.value = parseExpr();
                        s.inits ~= fi;
                        if (accept(Tk.comma))
                        {
                            if (kind == Tk.rBrace)
                                break;
                            continue;
                        }
                        break;
                    }
                }
                expect(Tk.rBrace);
                return s;
            }
            auto pe = new PathExpr;
            pe.pos = firstPos;
            pe.qual = qual;
            pe.qualPos = qualPos;
            pe.name = name;
            pe.namePos = namePos;
            return pe;
        }
        default:
            err();
        }
    }

    private Expr parseLambda()
    {
        auto l = new Lambda;
        l.pos = cur.pos;
        if (accept(Tk.orOr))
        {
        }
        else
        {
            expect(Tk.pipe);
            while (true)
            {
                LParam lp;
                lp.pos = cur.pos;
                lp.name = expectIdent();
                if (accept(Tk.colon))
                    lp.te = parseType();
                l.params ~= lp;
                if (accept(Tk.comma))
                {
                    if (kind == Tk.pipe)
                        break;
                    continue;
                }
                break;
            }
            expect(Tk.pipe);
        }
        if (accept(Tk.arrow))
            l.retTe = parseType();
        if (kind == Tk.lBrace)
            l.body = parseBlock();
        else
            l.body = parseExpr();
        return l;
    }

    private IfExpr parseIf()
    {
        auto e = new IfExpr;
        e.pos = advance().pos;
        e.cond = parseExpr();
        e.then = parseBlock();
        if (accept(Tk.kwElse))
        {
            if (kind == Tk.kwIf)
                e.els = parseIf();
            else
                e.els = parseBlock();
        }
        return e;
    }

    private MatchExpr parseMatch()
    {
        auto m = new MatchExpr;
        m.pos = advance().pos;
        m.scrut = parseExpr();
        expect(Tk.lBrace);
        while (kind != Tk.rBrace)
        {
            auto arm = new MatchArm;
            arm.pat = parsePattern();
            if (accept(Tk.kwWhen))
                arm.guard = parseExpr();
            expect(Tk.arrow);
            bool blockBody = kind == Tk.lBrace;
            if (blockBody)
                arm.body = parseBlock();
            else
                arm.body = parseExpr();
            m.arms ~= arm;
            if (accept(Tk.comma))
                continue;
            if (kind == Tk.rBrace)
                break;
            if (!blockBody)
                err();
        }
        expect(Tk.rBrace);
        return m;
    }

    // ------------------------------------------------------------ patterns

    private Pat parsePattern()
    {
        auto t = cur;
        switch (t.kind)
        {
        case Tk.underscore:
        {
            advance();
            auto w = new WildPat;
            w.pos = t.pos;
            return w;
        }
        case Tk.intLit, Tk.floatLit, Tk.minus:
        {
            advance();
            auto l = new LitPat;
            l.pos = t.pos;
            Token num = t;
            bool neg = false;
            if (t.kind == Tk.minus)
            {
                neg = true;
                if (kind != Tk.intLit && kind != Tk.floatLit)
                    err();
                num = advance();
            }
            if (num.kind == Tk.intLit)
            {
                l.kind = LitPat.Kind.int_;
                l.iv = neg ? -num.ival : num.ival;
            }
            else
            {
                l.kind = LitPat.Kind.float_;
                l.fv = neg ? -num.fval : num.fval;
            }
            return l;
        }
        case Tk.strLit:
        {
            advance();
            auto l = new LitPat;
            l.pos = t.pos;
            l.kind = LitPat.Kind.str;
            l.sv = t.sval;
            return l;
        }
        case Tk.charLit:
        {
            advance();
            auto l = new LitPat;
            l.pos = t.pos;
            l.kind = LitPat.Kind.char_;
            l.iv = t.ival;
            return l;
        }
        case Tk.kwTrue, Tk.kwFalse:
        {
            advance();
            auto l = new LitPat;
            l.pos = t.pos;
            l.kind = LitPat.Kind.bool_;
            l.iv = t.kind == Tk.kwTrue ? 1 : 0;
            return l;
        }
        case Tk.lParen:
        {
            advance();
            auto tp = new TuplePat;
            tp.pos = t.pos;
            tp.subs ~= parsePattern();
            expect(Tk.comma);
            while (true)
            {
                tp.subs ~= parsePattern();
                if (accept(Tk.comma))
                {
                    if (kind == Tk.rParen)
                        break;
                    continue;
                }
                break;
            }
            expect(Tk.rParen);
            return tp;
        }
        case Tk.lBracket:
        {
            advance();
            auto lp = new ListPat;
            lp.pos = t.pos;
            while (kind != Tk.rBracket)
            {
                if (kind == Tk.dotDot)
                {
                    advance();
                    lp.hasRest = true;
                    if (kind == Tk.ident)
                    {
                        lp.restPos = cur.pos;
                        lp.restName = advance().text;
                    }
                    break;
                }
                lp.subs ~= parsePattern();
                if (!accept(Tk.comma))
                    break;
            }
            expect(Tk.rBracket);
            return lp;
        }
        case Tk.ident:
        {
            advance();
            string qual;
            Pos qualPos;
            string name = t.text;
            Pos namePos = t.pos;
            if (accept(Tk.colonColon))
            {
                qual = name;
                qualPos = namePos;
                namePos = cur.pos;
                name = expectIdent();
            }
            if (kind == Tk.dot && kindAt(1) == Tk.lBrace)
            {
                advance();
                advance();
                auto sp = new StructPat;
                sp.pos = t.pos;
                sp.qual = qual;
                sp.qualPos = qualPos;
                sp.name = name;
                sp.namePos = namePos;
                while (kind != Tk.rBrace)
                {
                    if (kind == Tk.dotDot)
                    {
                        advance();
                        sp.dots = true;
                        break;
                    }
                    FieldPat fp;
                    fp.pos = cur.pos;
                    fp.name = expectIdent();
                    if (accept(Tk.colon))
                        fp.sub = parsePattern();
                    else
                    {
                        auto ip = new IdentPat;
                        ip.pos = fp.pos;
                        ip.name = fp.name;
                        ip.forceBind = true;
                        fp.sub = ip;
                    }
                    sp.fields ~= fp;
                    if (!accept(Tk.comma))
                        break;
                }
                expect(Tk.rBrace);
                return sp;
            }
            if (kind == Tk.lParen)
            {
                advance();
                auto vp = new VariantPat;
                vp.pos = t.pos;
                vp.qual = qual;
                vp.qualPos = qualPos;
                vp.name = name;
                vp.namePos = namePos;
                vp.parens = true;
                while (true)
                {
                    vp.subs ~= parsePattern();
                    if (accept(Tk.comma))
                    {
                        if (kind == Tk.rParen)
                            break;
                        continue;
                    }
                    break;
                }
                expect(Tk.rParen);
                return vp;
            }
            if (qual.length)
            {
                auto vp = new VariantPat;
                vp.pos = t.pos;
                vp.qual = qual;
                vp.qualPos = qualPos;
                vp.name = name;
                vp.namePos = namePos;
                return vp;
            }
            auto ip = new IdentPat;
            ip.pos = t.pos;
            ip.name = name;
            return ip;
        }
        default:
            err();
        }
    }
}
