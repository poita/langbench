/// Recursive-descent parser from tokens to the syntax tree.
module jinjalite.parser;

import std.conv : to;
import jinjalite.ast;
import jinjalite.errors;
import jinjalite.filters : FilterId, lookupFilter;
import jinjalite.lexer;
import jinjalite.operators : BinOp, CmpOp;
import jinjalite.value : Value;

/++
    Lex and parse `source` into a `Template`.

    Throws a `syntax` `TemplateError` for any syntax problem and then, if the
    template is well-formed, a `filter` `TemplateError` when any filter name
    used anywhere in it is unknown.
+/
Template parseTemplate(string name, string source)
{
    auto parser = new Parser(name, source);
    return parser.parse();
}

private final class Parser
{
    private string name_;
    private string src_;
    private Item[] items_;
    private size_t pos_;
    // The tag currently being parsed.
    private Token[] toks_;
    private size_t tp_;
    private size_t tagOffset_;

    private size_t depth_;
    private bool seenExtends_;
    private bool unknownFilter_;
    private Template tpl_;

    this(string name, string src)
    {
        name_ = name;
        src_ = src;
    }

    Template parse()
    {
        try
        {
            items_ = scan(src_);
            tpl_ = new Template(name_);
            tpl_.stmts = parseBody();
            if (pos_ < items_.length)
            {
                selectTag(items_[pos_]);
                fail("unexpected '" ~ toks_[0].text ~ "' tag");
            }
        }
        catch (TemplateError e)
        {
            if (e.kind == ErrorKind.syntax)
                e.msg = name_ ~ ": " ~ e.msg;
            throw e;
        }
        if (unknownFilter_)
            throw new TemplateError(ErrorKind.filter, name_ ~ ": unknown filter");
        return tpl_;
    }

    // ---- errors and token cursor -------------------------------------------------

    private noreturn fail(string message)
    {
        syntaxError("line " ~ lineOf(src_, tagOffset_).to!string ~ ": " ~ message);
    }

    private void selectTag(ref Item item)
    {
        toks_ = item.tokens;
        tp_ = 0;
        tagOffset_ = item.offset;
    }

    private ref Token cur() { return toks_[tp_]; }

    private Tok peekKind(size_t ahead = 1)
    {
        const idx = tp_ + ahead;
        return idx < toks_.length ? toks_[idx].kind : Tok.eof;
    }

    private bool accept(Tok kind)
    {
        if (cur.kind == kind)
        {
            ++tp_;
            return true;
        }
        return false;
    }

    private void expect(Tok kind, string what)
    {
        if (!accept(kind))
            fail("expected " ~ what);
    }

    private void expectEnd()
    {
        if (cur.kind != Tok.eof)
            fail("unexpected token after the end of the statement");
    }

    /// A variable-like name: an identifier that is not a keyword.
    private string expectName(string what)
    {
        if (cur.kind != Tok.name)
            fail("expected " ~ what);
        return toks_[tp_++].text;
    }

    // ---- statements ---------------------------------------------------------------

    private static bool isTerminator(string kw) pure nothrow @safe @nogc
    {
        switch (kw)
        {
        case "elif", "else", "endif", "endfor", "endmacro", "endblock":
            return true;
        default:
            return false;
        }
    }

    /// Parse items until a closing tag (left unconsumed) or the end of the template.
    private Stmt[] parseBody()
    {
        Stmt[] result;
        while (pos_ < items_.length)
        {
            auto item = &items_[pos_];
            final switch (item.kind)
            {
            case ItemKind.text:
                result ~= new TextStmt(item.text);
                ++pos_;
                break;
            case ItemKind.print:
                selectTag(*item);
                ++pos_;
                auto e = parseExpr();
                expectEnd();
                result ~= new PrintStmt(e);
                break;
            case ItemKind.statement:
                selectTag(*item);
                if (cur.kind != Tok.name)
                    fail("a statement must start with a keyword");
                const kw = cur.text;
                if (isTerminator(kw))
                    return result;
                ++pos_;
                ++tp_;
                result ~= parseStatement(kw);
                break;
            }
        }
        return result;
    }

    /// Consume the closing tag that ended a body and return its keyword.
    private string takeTerminator()
    {
        if (pos_ >= items_.length)
            fail("unexpected end of template: a block is not closed");
        selectTag(items_[pos_++]);
        const kw = cur.text;
        ++tp_;
        return kw;
    }

    private Stmt parseStatement(string kw)
    {
        switch (kw)
        {
        case "if":      return parseIf();
        case "for":     return parseFor();
        case "set":     return parseSet();
        case "macro":   return parseMacro();
        case "block":   return parseBlock();
        case "include":
        {
            auto target = parseExpr();
            expectEnd();
            return new IncludeStmt(target);
        }
        case "extends":
        {
            if (depth_ > 0)
                fail("'extends' must be at the top level of a template");
            if (seenExtends_)
                fail("a template may have only one 'extends'");
            seenExtends_ = true;
            auto target = parseExpr();
            expectEnd();
            return new ExtendsStmt(target);
        }
        default:
            fail("unknown statement '" ~ kw ~ "'");
        }
    }

    private Stmt parseIf()
    {
        auto stmt = new IfStmt;
        auto cond = parseExpr();
        expectEnd();
        ++depth_;
        while (true)
        {
            auto stmts = parseBody();
            stmt.conds ~= cond;
            stmt.bodies ~= stmts;
            string kw = takeTerminator();
            if (kw == "elif")
            {
                cond = parseExpr();
                expectEnd();
                continue;
            }
            if (kw == "else")
            {
                expectEnd();
                stmt.elseBody = parseBody();
                kw = takeTerminator();
            }
            if (kw != "endif")
                fail("expected 'endif', found '" ~ kw ~ "'");
            expectEnd();
            break;
        }
        --depth_;
        return stmt;
    }

    private Stmt parseFor()
    {
        const var = expectName("a loop variable name");
        expect(Tok.kwIn, "'in'");
        auto iterable = parseExpr();
        expectEnd();
        auto stmt = new ForStmt(var, iterable);
        ++depth_;
        stmt.stmts = parseBody();
        string kw = takeTerminator();
        if (kw == "else")
        {
            expectEnd();
            stmt.elseBody = parseBody();
            kw = takeTerminator();
        }
        if (kw != "endfor")
            fail("expected 'endfor', found '" ~ kw ~ "'");
        expectEnd();
        --depth_;
        return stmt;
    }

    private Stmt parseSet()
    {
        const var = expectName("a variable name");
        expect(Tok.assign, "'='");
        auto value = parseExpr();
        expectEnd();
        return new SetStmt(var, value);
    }

    private Stmt parseMacro()
    {
        auto stmt = new MacroStmt(expectName("a macro name"));
        expect(Tok.lparen, "'('");
        if (cur.kind != Tok.rparen)
        {
            while (true)
            {
                Param param;
                param.name = expectName("a parameter name");
                foreach (prev; stmt.params)
                    if (prev.name == param.name)
                        fail("duplicate macro parameter '" ~ param.name ~ "'");
                if (accept(Tok.assign))
                    param.defaultValue = parseExpr();
                stmt.params ~= param;
                if (accept(Tok.comma))
                    continue;
                break;
            }
        }
        expect(Tok.rparen, "')'");
        expectEnd();
        ++depth_;
        stmt.stmts = parseBody();
        const kw = takeTerminator();
        if (kw != "endmacro")
            fail("expected 'endmacro', found '" ~ kw ~ "'");
        expectEnd();
        --depth_;
        return stmt;
    }

    private Stmt parseBlock()
    {
        const blockName = expectName("a block name");
        expectEnd();
        auto stmt = new BlockStmt(blockName);
        if (blockName in tpl_.blocks)
            fail("block '" ~ blockName ~ "' defined twice");
        tpl_.blocks[blockName] = stmt;
        ++depth_;
        stmt.stmts = parseBody();
        const kw = takeTerminator();
        if (kw != "endblock")
            fail("expected 'endblock', found '" ~ kw ~ "'");
        if (cur.kind == Tok.name)
        {
            if (cur.text != blockName)
                fail("'endblock' name does not match block '" ~ blockName ~ "'");
            ++tp_;
        }
        expectEnd();
        --depth_;
        return stmt;
    }

    // ---- expressions --------------------------------------------------------------

    private Expr parseExpr()
    {
        return parseOr();
    }

    private Expr parseOr()
    {
        auto lhs = parseAnd();
        while (accept(Tok.kwOr))
            lhs = new LogicExpr(false, lhs, parseAnd());
        return lhs;
    }

    private Expr parseAnd()
    {
        auto lhs = parseNot();
        while (accept(Tok.kwAnd))
            lhs = new LogicExpr(true, lhs, parseNot());
        return lhs;
    }

    private Expr parseNot()
    {
        if (accept(Tok.kwNot))
            return new UnaryExpr(ExprKind.not, parseNot());
        return parseCompare();
    }

    private Expr parseCompare()
    {
        auto first = parseAdditive();
        CmpOp[] ops;
        Expr[] operands;
        while (true)
        {
            CmpOp op;
            switch (cur.kind)
            {
            case Tok.eq: op = CmpOp.eq; break;
            case Tok.ne: op = CmpOp.ne; break;
            case Tok.lt: op = CmpOp.lt; break;
            case Tok.le: op = CmpOp.le; break;
            case Tok.gt: op = CmpOp.gt; break;
            case Tok.ge: op = CmpOp.ge; break;
            case Tok.kwIn: op = CmpOp.in_; break;
            case Tok.kwNot:
                if (peekKind() != Tok.kwIn)
                    goto done;
                ++tp_;
                op = CmpOp.notIn;
                break;
            default:
                goto done;
            }
            ++tp_;
            ops ~= op;
            operands ~= parseAdditive();
        }
    done:
        if (ops.length == 0)
            return first;
        return new CompareExpr(first, ops, operands);
    }

    private Expr parseAdditive()
    {
        auto lhs = parseConcat();
        while (true)
        {
            if (accept(Tok.plus))
                lhs = new BinaryExpr(BinOp.add, lhs, parseConcat());
            else if (accept(Tok.minus))
                lhs = new BinaryExpr(BinOp.sub, lhs, parseConcat());
            else
                return lhs;
        }
    }

    private Expr parseConcat()
    {
        auto lhs = parseTerm();
        while (accept(Tok.tilde))
            lhs = new BinaryExpr(BinOp.concat, lhs, parseTerm());
        return lhs;
    }

    private Expr parseTerm()
    {
        auto lhs = parsePower();
        while (true)
        {
            BinOp op;
            switch (cur.kind)
            {
            case Tok.star: op = BinOp.mul; break;
            case Tok.slash: op = BinOp.div; break;
            case Tok.floorDiv: op = BinOp.floorDiv; break;
            case Tok.percent: op = BinOp.mod; break;
            default: return lhs;
            }
            ++tp_;
            lhs = new BinaryExpr(op, lhs, parsePower());
        }
    }

    private Expr parsePower()
    {
        auto lhs = parseFiltered();
        while (accept(Tok.pow))
            lhs = new BinaryExpr(BinOp.pow, lhs, parseFiltered());
        return lhs;
    }

    private Expr parseFiltered()
    {
        auto e = parseUnary();
        while (true)
        {
            if (accept(Tok.pipe))
            {
                const filterName = expectName("a filter name");
                Expr[] args;
                if (accept(Tok.lparen))
                {
                    if (cur.kind != Tok.rparen)
                    {
                        do
                            args ~= parseExpr();
                        while (accept(Tok.comma));
                    }
                    expect(Tok.rparen, "')'");
                }
                const id = lookupFilter(filterName);
                if (id == FilterId.unknown)
                    unknownFilter_ = true;
                e = new FilterExpr(e, id, args);
            }
            else if (accept(Tok.kwIs))
            {
                const negated = accept(Tok.kwNot);
                if (cur.kind != Tok.name || cur.text != "defined")
                    fail("only the 'defined' test exists");
                ++tp_;
                e = new IsDefinedExpr(e, negated);
            }
            else
                return e;
        }
    }

    private Expr parseUnary()
    {
        if (accept(Tok.minus))
            return new UnaryExpr(ExprKind.negate, parseUnary());
        return parsePostfix();
    }

    private Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (true)
        {
            if (accept(Tok.dot))
                e = new AttrExpr(e, expectName("an attribute name"));
            else if (accept(Tok.lbracket))
            {
                auto key = parseExpr();
                expect(Tok.rbracket, "']'");
                e = new SubscriptExpr(e, key);
            }
            else if (accept(Tok.lparen))
                e = parseCall(e);
            else
                return e;
        }
    }

    private Expr parseCall(Expr callee)
    {
        Expr[] args;
        string[] kwNames;
        Expr[] kwValues;
        if (cur.kind != Tok.rparen)
        {
            while (true)
            {
                if (cur.kind == Tok.name && peekKind() == Tok.assign)
                {
                    const kw = cur.text;
                    foreach (prev; kwNames)
                        if (prev == kw)
                            fail("keyword argument '" ~ kw ~ "' repeated");
                    tp_ += 2;
                    kwNames ~= kw;
                    kwValues ~= parseExpr();
                }
                else
                {
                    if (kwNames.length)
                        fail("positional argument after keyword argument");
                    args ~= parseExpr();
                }
                if (accept(Tok.comma))
                    continue;
                break;
            }
        }
        expect(Tok.rparen, "')'");
        return new CallExpr(callee, args, kwNames, kwValues);
    }

    private Expr parsePrimary()
    {
        const tok = cur;
        switch (tok.kind)
        {
        case Tok.integer:
            ++tp_;
            return new Literal(Value.integer(tok.intValue));
        case Tok.floating:
            ++tp_;
            return new Literal(Value.floating(tok.floatValue));
        case Tok.string_:
            ++tp_;
            return new Literal(Value.text(tok.text));
        case Tok.kwTrue:
            ++tp_;
            return new Literal(Value.boolean(true));
        case Tok.kwFalse:
            ++tp_;
            return new Literal(Value.boolean(false));
        case Tok.kwNone:
            ++tp_;
            return new Literal(Value.none);
        case Tok.name:
            ++tp_;
            return new NameExpr(tok.text);
        case Tok.lbracket:
        {
            ++tp_;
            Expr[] items;
            if (cur.kind != Tok.rbracket)
            {
                do
                    items ~= parseExpr();
                while (accept(Tok.comma));
            }
            expect(Tok.rbracket, "']'");
            return new ListExpr(items);
        }
        case Tok.lparen:
        {
            ++tp_;
            auto e = parseExpr();
            expect(Tok.rparen, "')'");
            return e;
        }
        default:
            fail("unexpected token in expression");
        }
    }
}

version (unittest)
{
    import std.exception : collectException;

    private ErrorKind kindOf(string src)
    {
        auto e = cast(TemplateError) collectException(parseTemplate("t", src));
        assert(e !is null, "expected an error for: " ~ src);
        return e.kind;
    }
}

unittest
{
    auto t = parseTemplate("t", "a{% if x %}b{% elif y %}c{% else %}d{% endif %}{% for i in l %}{{ i }}{% else %}e{% endfor %}");
    assert(t.stmts.length == 3);
    auto ifs = cast(IfStmt) t.stmts[1];
    assert(ifs.conds.length == 2 && ifs.elseBody.length == 1);
    auto fors = cast(ForStmt) t.stmts[2];
    assert(fors.var == "i" && fors.elseBody.length == 1);
}

unittest
{
    auto t = parseTemplate("t", "{% block a %}{% block b %}{% endblock b %}{% endblock %}{% macro m(x, y=1) %}{% endmacro %}");
    assert(t.blocks.length == 2 && "a" in t.blocks && "b" in t.blocks);
    auto m = cast(MacroStmt) t.stmts[1];
    assert(m.params.length == 2 && m.params[1].defaultValue !is null);
}

unittest
{
    // Precedence: filters bind tighter than binary operators, `not` looser than comparisons.
    auto t = parseTemplate("t", "{{ a * b|int }}{{ not a == b }}{{ -2 ** 2 }}{{ a < b < c }}");
    auto mul = cast(BinaryExpr) (cast(PrintStmt) t.stmts[0]).expr;
    assert(mul.op == BinOp.mul && mul.rhs.kind == ExprKind.filter);
    auto not = cast(UnaryExpr) (cast(PrintStmt) t.stmts[1]).expr;
    assert(not.kind == ExprKind.not && not.operand.kind == ExprKind.compare);
    auto pw = cast(BinaryExpr) (cast(PrintStmt) t.stmts[2]).expr;
    assert(pw.op == BinOp.pow && pw.lhs.kind == ExprKind.negate);
    auto chain = cast(CompareExpr) (cast(PrintStmt) t.stmts[3]).expr;
    assert(chain.ops.length == 2);
}

unittest
{
    assert(kindOf("{% if x %}") == ErrorKind.syntax);
    assert(kindOf("{% endif %}") == ErrorKind.syntax);
    assert(kindOf("{% else %}") == ErrorKind.syntax);
    assert(kindOf("{% if x %}{% else %}{% elif y %}{% endif %}") == ErrorKind.syntax);
    assert(kindOf("{% raw %}") == ErrorKind.syntax);
    assert(kindOf("{% %}") == ErrorKind.syntax);
    assert(kindOf("{{ }}") == ErrorKind.syntax);
    assert(kindOf("{{ 1 + }}") == ErrorKind.syntax);
    assert(kindOf("{{ x is odd }}") == ErrorKind.syntax);
    assert(kindOf("{{ f(a=1, 2) }}") == ErrorKind.syntax);
    assert(kindOf("{{ f(a=1, a=2) }}") == ErrorKind.syntax);
    assert(kindOf("{{ (1, 2) }}") == ErrorKind.syntax);
    assert(kindOf("{% for a, b in x %}{% endfor %}") == ErrorKind.syntax);
    assert(kindOf("{% for x in y if z %}{% endfor %}") == ErrorKind.syntax);
    assert(kindOf("{% set a, b = 1 %}") == ErrorKind.syntax);
    assert(kindOf("{% set in = 1 %}") == ErrorKind.syntax);
    assert(kindOf("{% macro m(a, a) %}{% endmacro %}") == ErrorKind.syntax);
    assert(kindOf("{% block a %}{% endblock b %}") == ErrorKind.syntax);
    assert(kindOf("{% block a %}{% endblock %}{% block a %}{% endblock %}") == ErrorKind.syntax);
    assert(kindOf(`{% extends "a" %}{% extends "b" %}`) == ErrorKind.syntax);
    assert(kindOf(`{% if x %}{% extends "a" %}{% endif %}`) == ErrorKind.syntax);
    assert(kindOf("{% endfor extra %}") == ErrorKind.syntax);
}

unittest
{
    // Syntax errors win over unknown filters; unknown filters are found anywhere.
    assert(kindOf("{{ x|nope }}{% if %}") == ErrorKind.syntax);
    assert(kindOf("{% if false %}{{ x|nope }}{% endif %}") == ErrorKind.filter);
    assert(kindOf("{% macro m(a=1|nope) %}{% endmacro %}") == ErrorKind.filter);
}
