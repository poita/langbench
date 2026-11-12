/// Recursive-descent parser producing a `Program`.
module datalog.parser;

import datalog.ast;
import datalog.errors;
import datalog.lexer;
import datalog.symbols;

/// Parses a whole program. Throws `ParseException` if the text is malformed.
Program parseProgram(string source) @safe pure
{
    auto p = Parser(tokenize(source), new Program);
    p.parseAll();
    return p.program;
}

private struct Parser
{
    Token[] tokens;
    Program program;
    size_t pos;
    uint[string] varSlots;
    uint numVars;

    ref const(Token) peek(size_t ahead = 0) const @safe pure nothrow @nogc
    {
        immutable i = pos + ahead;
        return tokens[i < tokens.length ? i : tokens.length - 1];
    }

    Token take() @safe pure nothrow @nogc
    {
        auto t = tokens[pos];
        if (pos + 1 < tokens.length)
            ++pos;
        return t;
    }

    Token expect(TokenKind k, string what) @safe pure
    {
        if (peek.kind != k)
            throw new ParseException("expected " ~ what, peek.line);
        return take();
    }

    void parseAll() @safe pure
    {
        while (peek.kind != TokenKind.eof)
            parseClause();
    }

    void startClause() @safe pure nothrow
    {
        varSlots = null;
        numVars = 0;
    }

    void parseClause() @safe pure
    {
        startClause();
        if (peek.kind == TokenKind.queryMark)
        {
            take();
            auto atom = parseAtom();
            expect(TokenKind.dot, "'.'");
            program.queries ~= Query(atom, numVars);
            return;
        }
        auto head = parseAtom();
        Literal[] body;
        if (peek.kind == TokenKind.implies)
        {
            take();
            body ~= parseLiteral();
            while (peek.kind == TokenKind.comma)
            {
                take();
                body ~= parseLiteral();
            }
        }
        expect(TokenKind.dot, "'.' at end of clause");
        program.rules ~= Rule(head, body, numVars);
    }

    Atom parseAtom() @safe pure
    {
        auto name = expect(TokenKind.identifier, "predicate name");
        expect(TokenKind.lparen, "'('");
        Term[] args;
        args ~= parseTerm();
        while (peek.kind == TokenKind.comma)
        {
            take();
            args ~= parseTerm();
        }
        expect(TokenKind.rparen, "')'");
        return Atom(program.predicateId(name.text, cast(uint) args.length), args);
    }

    Term parseTerm() @safe pure
    {
        auto t = take();
        switch (t.kind)
        {
        case TokenKind.identifier:
            return Term(TermKind.constant, program.symbols.intern(Constant.symbol(t.text)));
        case TokenKind.integer:
            return Term(TermKind.constant, program.symbols.intern(Constant.integer(t.value)));
        case TokenKind.anonymous:
            return Term(TermKind.variable, numVars++);
        case TokenKind.variable:
            if (auto s = t.text in varSlots)
                return Term(TermKind.variable, *s);
            varSlots[t.text] = numVars;
            return Term(TermKind.variable, numVars++);
        default:
            throw new ParseException("expected a term", t.line);
        }
    }

    Literal parseLiteral() @safe pure
    {
        Literal lit;
        if (peek.kind == TokenKind.not)
        {
            take();
            lit.kind = LiteralKind.negated;
            lit.atom = parseAtom();
            return lit;
        }
        if (peek.kind == TokenKind.identifier && peek(1).kind == TokenKind.lparen)
        {
            lit.kind = LiteralKind.positive;
            lit.atom = parseAtom();
            return lit;
        }
        lit.kind = LiteralKind.comparison;
        lit.lhs = parseTerm();
        auto op = take();
        switch (op.kind)
        {
        case TokenKind.lt: lit.op = CmpOp.lt; break;
        case TokenKind.le: lit.op = CmpOp.le; break;
        case TokenKind.gt: lit.op = CmpOp.gt; break;
        case TokenKind.ge: lit.op = CmpOp.ge; break;
        case TokenKind.eq: lit.op = CmpOp.eq; break;
        case TokenKind.ne: lit.op = CmpOp.ne; break;
        default:
            throw new ParseException("expected a comparison operator", op.line);
        }
        lit.rhs = parseTerm();
        return lit;
    }
}

@safe pure unittest
{
    auto p = parseProgram("edge(1, 2). path(X, Z) :- edge(X, Y), not path(Y, _), X < Z. ?- path(1, X).");
    assert(p.rules.length == 2);
    assert(p.queries.length == 1);
    assert(p.rules[0].body.length == 0);
    auto r = p.rules[1];
    assert(r.body.length == 3);
    assert(r.body[0].kind == LiteralKind.positive);
    assert(r.body[1].kind == LiteralKind.negated);
    assert(r.body[2].kind == LiteralKind.comparison && r.body[2].op == CmpOp.lt);
    assert(r.numVars == 4); // X, Z, Y, and the anonymous variable
    assert(r.body[1].atom.args[1].id == 3);
    // edge/2 and path/2 and nothing else
    assert(p.predicates.length == 2);
}

@safe pure unittest
{
    // One name, two arities: two predicates.
    auto p = parseProgram("r(1). r(1, 2). ?- r(X).");
    assert(p.predicates.length == 2);
    assert(p.predicates[0] == Predicate("r", 1));
    assert(p.predicates[1] == Predicate("r", 2));
}

@safe pure unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(parseProgram("p(a)"));
    assertThrown!ParseException(parseProgram("p(a) :- ."));
    assertThrown!ParseException(parseProgram("p() ."));
    assertThrown!ParseException(parseProgram("p(X) :- X ~ 3."));
}
