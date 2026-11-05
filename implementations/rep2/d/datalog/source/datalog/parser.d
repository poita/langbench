/// Single-pass parser: turns source text into a `Program`, interning constants and
/// predicates as it goes, then renumbering constants into total order.
module datalog.parser;

import std.algorithm : sort;
import datalog.ast;
import datalog.errors : ParseException;
import datalog.lexer;

/// Parse a complete program.
///
/// Throws: `ParseException` if the text is not well-formed.
Program parseProgram(string source)
{
    auto p = Parser(source);
    return p.parse();
}

private struct Parser
{
    Lexer lexer;
    Token cur;

    Program prog;
    uint[string] constIndex;   // constant text -> provisional id
    uint[string] predIndex;    // "name/arity" -> PredId
    uint[string] varSlots;     // variable name -> slot, per clause
    uint nextSlot;

    this(string source)
    {
        lexer = Lexer(source);
        cur = lexer.next();
    }

    void advance() { cur = lexer.next(); }

    ParseException error(string msg) { return new ParseException(msg, cur.offset); }

    void expect(TokenKind k, string what)
    {
        if (cur.kind != k) throw error("expected " ~ what);
        advance();
    }

    Program parse()
    {
        while (cur.kind != TokenKind.eof)
            clause();
        renumberConstants();
        return prog;
    }

    void clause()
    {
        varSlots.clear();
        nextSlot = 0;
        if (cur.kind == TokenKind.queryMark)
        {
            advance();
            auto a = atom();
            expect(TokenKind.dot, "'.'");
            prog.queries ~= Query(a, nextSlot);
            return;
        }
        auto head = atom();
        Literal[] body;
        if (cur.kind == TokenKind.implies)
        {
            advance();
            body ~= literal();
            while (cur.kind == TokenKind.comma)
            {
                advance();
                body ~= literal();
            }
        }
        expect(TokenKind.dot, "'.'");
        prog.rules ~= Rule(head, body, nextSlot);
    }

    Literal literal()
    {
        Literal lit;
        if (cur.kind == TokenKind.kwNot)
        {
            advance();
            lit.kind = LiteralKind.negative;
            lit.atom = atom();
            return lit;
        }
        if (cur.kind == TokenKind.identifier)
        {
            auto name = cur;
            advance();
            if (cur.kind == TokenKind.lparen)
            {
                lit.kind = LiteralKind.positive;
                lit.atom = atomRest(name);
                return lit;
            }
            lit.lhs = Term.constant(internConstant(name.text));
        }
        else
            lit.lhs = term();
        lit.kind = LiteralKind.comparison;
        switch (cur.kind)
        {
        case TokenKind.lt: lit.op = CmpOp.lt; break;
        case TokenKind.le: lit.op = CmpOp.le; break;
        case TokenKind.gt: lit.op = CmpOp.gt; break;
        case TokenKind.ge: lit.op = CmpOp.ge; break;
        case TokenKind.eq: lit.op = CmpOp.eq; break;
        case TokenKind.ne: lit.op = CmpOp.ne; break;
        default: throw error("expected comparison operator");
        }
        advance();
        lit.rhs = term();
        return lit;
    }

    Atom atom()
    {
        if (cur.kind != TokenKind.identifier) throw error("expected predicate name");
        auto name = cur;
        advance();
        return atomRest(name);
    }

    /// Parse `( term, ... )` after the predicate name token has been consumed.
    Atom atomRest(Token name)
    {
        expect(TokenKind.lparen, "'('");
        Term[] args;
        args ~= term();
        while (cur.kind == TokenKind.comma)
        {
            advance();
            args ~= term();
        }
        expect(TokenKind.rparen, "')'");
        return Atom(internPredicate(name.text, cast(uint) args.length), args);
    }

    Term term()
    {
        Term t;
        switch (cur.kind)
        {
        case TokenKind.identifier:
        case TokenKind.integer:
            t = Term.constant(internConstant(cur.text));
            break;
        case TokenKind.variable:
            if (auto s = cur.text in varSlots)
                t = Term.variable(*s);
            else
            {
                varSlots[cur.text] = nextSlot;
                t = Term.variable(nextSlot++);
            }
            break;
        case TokenKind.anonymous:
            t = Term.variable(nextSlot++);
            break;
        default:
            throw error("expected a term");
        }
        advance();
        return t;
    }

    uint internConstant(string text)
    {
        if (auto p = text in constIndex) return *p;
        immutable id = cast(uint) prog.constants.length;
        prog.constants ~= text;
        constIndex[text] = id;
        return id;
    }

    PredId internPredicate(string name, uint arity)
    {
        import std.conv : to;
        immutable key = name ~ "/" ~ arity.to!string;
        if (auto p = key in predIndex) return *p;
        immutable id = cast(PredId) prog.predicates.length;
        prog.predicates ~= Predicate(name, arity);
        predIndex[key] = id;
        return id;
    }

    /// Sort constants into the total order and rewrite every constant term to its rank.
    void renumberConstants()
    {
        auto texts = prog.constants;
        immutable n = texts.length;
        auto order = new uint[n];
        foreach (i; 0 .. n) order[i] = cast(uint) i;
        order.sort!((a, b) => constantLess(texts[a], texts[b]));
        auto rank = new uint[n];
        auto sorted = new string[n];
        foreach (r, id; order)
        {
            rank[id] = cast(uint) r;
            sorted[r] = texts[id];
        }
        prog.constants = sorted;

        void fix(ref Term t) { if (!t.isVar) t.id = rank[t.id]; }
        void fixAtom(ref Atom a) { foreach (ref t; a.args) fix(t); }
        foreach (ref r; prog.rules)
        {
            fixAtom(r.head);
            foreach (ref l; r.body)
            {
                if (l.kind == LiteralKind.comparison) { fix(l.lhs); fix(l.rhs); }
                else fixAtom(l.atom);
            }
        }
        foreach (ref q; prog.queries) fixAtom(q.atom);
    }
}

/// True if the constant with text `a` sorts strictly before the one with text `b`:
/// integers numerically, before identifiers, which compare bytewise.
bool constantLess(string a, string b) @safe pure
{
    immutable ai = isIntegerText(a), bi = isIntegerText(b);
    if (ai && bi) return parseInteger(a) < parseInteger(b);
    if (ai != bi) return ai;
    return a < b;
}

private bool isIntegerText(string s) @safe pure nothrow @nogc
{
    return s[0] == '-' || (s[0] >= '0' && s[0] <= '9');
}

private long parseInteger(string s) @safe pure nothrow @nogc
{
    size_t i = s[0] == '-' ? 1 : 0;
    long v = 0;
    for (; i < s.length; ++i)
        v = v * 10 + (s[i] - '0');
    return s[0] == '-' ? -v : v;
}
