/// Recursive-descent parser producing a `Program`.
module datalog.parser;

import datalog.ast;
import datalog.errors : SyntaxException;
import datalog.lexer;
import std.conv : to;

/// Parses Datalog source text.
///
/// Every `_` becomes a fresh variable. Variable indices are local to a clause.
///
/// Throws: `SyntaxException` if the text is not a well-formed program.
Program parseProgram(string source) @safe
{
    auto p = Parser(tokenize(source), new Program);
    p.parseAll();
    return p.prog;
}

private struct Parser
{
    Token[] toks;
    Program prog;
    size_t pos;
    uint[string] vars;
    uint numVars;

    this(Token[] toks, Program prog) @safe
    {
        this.toks = toks;
        this.prog = prog;
    }

    ref const(Token) peek(size_t ahead = 0) const @safe
    {
        auto i = pos + ahead;
        return toks[i < toks.length ? i : toks.length - 1];
    }

    Token expect(TokenKind k, string what) @safe
    {
        auto t = peek;
        if (t.kind != k)
            throw new SyntaxException("line " ~ t.line.to!string ~ ": expected " ~ what
                    ~ " but found '" ~ t.text ~ "'");
        ++pos;
        return t;
    }

    void parseAll() @safe
    {
        while (peek.kind != TokenKind.eof)
            parseClause();
    }

    void parseClause() @safe
    {
        vars = null;
        numVars = 0;
        if (peek.kind == TokenKind.queryMark)
        {
            ++pos;
            auto a = parseAtom();
            expect(TokenKind.dot, "'.'");
            prog.queries ~= Query(a, numVars);
            return;
        }
        auto head = parseAtom();
        Literal[] body;
        if (peek.kind == TokenKind.neck)
        {
            ++pos;
            body ~= parseLiteral();
            while (peek.kind == TokenKind.comma)
            {
                ++pos;
                body ~= parseLiteral();
            }
        }
        expect(TokenKind.dot, "'.'");
        prog.rules ~= Rule(head, body, numVars);
    }

    Atom parseAtom() @safe
    {
        auto name = expect(TokenKind.identifier, "a predicate name");
        expect(TokenKind.lparen, "'('");
        Term[] args;
        args ~= parseTerm();
        while (peek.kind == TokenKind.comma)
        {
            ++pos;
            args ~= parseTerm();
        }
        expect(TokenKind.rparen, "')'");
        return Atom(prog.predicate(name.text, cast(uint) args.length), args);
    }

    Term parseTerm() @safe
    {
        auto t = peek;
        switch (t.kind)
        {
        case TokenKind.identifier:
            ++pos;
            return Term.constant(prog.symbols.internName(t.text));
        case TokenKind.integer:
            ++pos;
            return Term.constant(prog.symbols.internInt(t.value));
        case TokenKind.variable:
            ++pos;
            if (auto v = t.text in vars)
                return Term.variable(*v);
            vars[t.text] = numVars;
            return Term.variable(numVars++);
        case TokenKind.anonymous:
            ++pos;
            return Term.variable(numVars++);
        default:
            throw new SyntaxException("line " ~ t.line.to!string ~ ": expected a term but found '"
                    ~ t.text ~ "'");
        }
    }

    Literal parseLiteral() @safe
    {
        Literal lit;
        if (peek.kind == TokenKind.kwNot)
        {
            ++pos;
            lit.kind = LiteralKind.negative;
            lit.atom = parseAtom();
        }
        else if (peek.kind == TokenKind.identifier && peek(1).kind == TokenKind.lparen)
        {
            lit.kind = LiteralKind.positive;
            lit.atom = parseAtom();
        }
        else
        {
            lit.kind = LiteralKind.comparison;
            lit.lhs = parseTerm();
            auto t = peek;
            switch (t.kind)
            {
            case TokenKind.lt: lit.op = CmpOp.lt; break;
            case TokenKind.le: lit.op = CmpOp.le; break;
            case TokenKind.gt: lit.op = CmpOp.gt; break;
            case TokenKind.ge: lit.op = CmpOp.ge; break;
            case TokenKind.eq: lit.op = CmpOp.eq; break;
            case TokenKind.ne: lit.op = CmpOp.ne; break;
            default:
                throw new SyntaxException("line " ~ t.line.to!string
                        ~ ": expected a comparison operator but found '" ~ t.text ~ "'");
            }
            ++pos;
            lit.rhs = parseTerm();
        }
        return lit;
    }
}

@("parser: facts, rules and queries")
@safe unittest
{
    auto p = parseProgram("edge(1, a). path(X, Y) :- edge(X, Y), not bad(Y), X < Y. ?- path(_, _).");
    assert(p.rules.length == 2 && p.queries.length == 1);
    assert(p.rules[0].body.length == 0);
    assert(p.rules[1].body.length == 3);
    assert(p.rules[1].body[1].kind == LiteralKind.negative);
    assert(p.rules[1].body[2].kind == LiteralKind.comparison);
    assert(p.rules[1].numVars == 2);
    // each `_` is a distinct variable
    assert(p.queries[0].numVars == 2);
    assert(p.predicates.length == 3);
}

@("parser: same name with different arities are different predicates")
@safe unittest
{
    auto p = parseProgram("r(a). r(a, b).");
    assert(p.predicates.length == 2);
    assert(p.rules[0].head.pred != p.rules[1].head.pred);
}

@("parser: syntax errors are reported")
@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!SyntaxException(parseProgram("p(a)"));
    assertThrown!SyntaxException(parseProgram("p(a) :- ."));
    assertThrown!SyntaxException(parseProgram("p :- q(a)."));
}
