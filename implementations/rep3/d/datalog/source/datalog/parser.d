/**
 * Recursive-descent parser producing a `Program`.
 *
 * Constants and predicates are interned while parsing, and the constants are
 * renumbered into their total order at the end, so the returned program is
 * ready for analysis and evaluation.
 */
module datalog.parser;

import datalog.ast;
import datalog.lexer;

/// Maximum predicate arity supported by the engine.
enum maxArity = 32;

/**
 * Parses a whole program.
 *
 * Throws: `ParseException` on malformed input.
 */
Program parseProgram(string source)
{
    auto p = Parser(source);
    return p.parse();
}

private struct Parser
{
    Lexer lex;
    Token cur, ahead;
    Program prog;
    uint[string] vars;
    uint numVars;

    this(string source)
    {
        lex = Lexer(source);
        cur = lex.next();
        ahead = lex.next();
    }

    void advance()
    {
        cur = ahead;
        if (cur.kind != TokenKind.eof)
            ahead = lex.next();
    }

    Token expect(TokenKind k, string what)
    {
        if (cur.kind != k)
            throw new ParseException("expected " ~ what ~ ", found '" ~ cur.text ~ "'", cur.line);
        auto t = cur;
        advance();
        return t;
    }

    Program parse()
    {
        while (cur.kind != TokenKind.eof)
            clause();
        prog.sortConstants();
        return prog;
    }

    void clause()
    {
        vars = null;
        numVars = 0;
        if (cur.kind == TokenKind.queryArrow)
        {
            advance();
            auto a = atom();
            expect(TokenKind.dot, "'.'");
            prog.queries ~= Query(a, numVars);
            return;
        }
        auto head = atom();
        Literal[] body;
        if (cur.kind == TokenKind.ruleArrow)
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
        prog.rules ~= Rule(head, body, numVars);
    }

    Atom atom()
    {
        auto name = expect(TokenKind.identifier, "predicate name");
        expect(TokenKind.lparen, "'('");
        Term[] args;
        args ~= term();
        while (cur.kind == TokenKind.comma)
        {
            advance();
            args ~= term();
        }
        expect(TokenKind.rparen, "')'");
        if (args.length > maxArity)
            throw new ParseException("too many arguments", name.line);
        return Atom(prog.predicate(name.text, cast(uint) args.length), args);
    }

    Literal literal()
    {
        Literal l;
        if (cur.kind == TokenKind.kwNot)
        {
            advance();
            l.kind = LiteralKind.negative;
            l.atom = atom();
        }
        else if (cur.kind == TokenKind.identifier && ahead.kind == TokenKind.lparen)
        {
            l.kind = LiteralKind.positive;
            l.atom = atom();
        }
        else
        {
            l.kind = LiteralKind.comparison;
            l.lhs = term();
            l.op = cmpOp();
            l.rhs = term();
        }
        return l;
    }

    CmpOp cmpOp()
    {
        CmpOp op;
        switch (cur.kind)
        {
        case TokenKind.lt: op = CmpOp.lt; break;
        case TokenKind.le: op = CmpOp.le; break;
        case TokenKind.gt: op = CmpOp.gt; break;
        case TokenKind.ge: op = CmpOp.ge; break;
        case TokenKind.eq: op = CmpOp.eq; break;
        case TokenKind.ne: op = CmpOp.ne; break;
        default:
            throw new ParseException("expected comparison operator, found '" ~ cur.text ~ "'", cur.line);
        }
        advance();
        return op;
    }

    Term term()
    {
        const t = cur;
        switch (t.kind)
        {
        case TokenKind.integer:
            advance();
            return Term.constant(prog.intConstant(t.value));
        case TokenKind.identifier:
            advance();
            return Term.constant(prog.nameConstant(t.text));
        case TokenKind.variable:
            advance();
            if (auto s = t.text in vars)
                return Term.var(*s);
            vars[t.text] = numVars;
            return Term.var(numVars++);
        case TokenKind.anonymous:
            advance();
            return Term.var(numVars++);
        default:
            throw new ParseException("expected a term, found '" ~ t.text ~ "'", t.line);
        }
    }
}
