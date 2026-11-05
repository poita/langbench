/// Recursive-descent parser producing a canonicalised `Program`.
module datalog.parser;

import datalog.ast;
import datalog.errors : ParseException;
import datalog.lexer;

/// Parse Datalog source text.
///
/// Constants and predicates are interned while parsing, then constant ids are
/// renumbered into the total order of constants (see `Program.canonicalize`).
/// Throws `ParseException` on malformed input.
Program parseProgram(string source) @safe
{
    auto parser = Parser(source);
    return parser.parse();
}

private struct VarScope
{
    string[] names;
    uint count;

    uint slot(string name) pure nothrow @safe
    {
        foreach (i, n; names)
            if (n == name)
                return cast(uint) i;
        // names[] only holds named variables; anonymous ones just consume a slot.
        names ~= name;
        return count++;
    }

    uint fresh() pure nothrow @safe
    {
        names ~= null; // never equals a real name
        return count++;
    }
}

private struct Parser
{
    Lexer lexer;
    Token[2] window;
    size_t filled;
    Program program;

    this(string source) @safe
    {
        lexer = Lexer(source);
        program = new Program;
    }

    Program parse() @safe
    {
        while (peek().kind != TokenKind.eof)
            parseClause();
        program.canonicalize();
        return program;
    }

private:
    ref const(Token) peek(size_t ahead = 0) return @safe
    {
        while (filled <= ahead)
            window[filled++] = lexer.next();
        return window[ahead];
    }

    Token advance() @safe
    {
        peek();
        auto t = window[0];
        window[0] = window[1];
        --filled;
        return t;
    }

    Token expect(TokenKind kind, string what) @safe
    {
        if (peek().kind != kind)
            throw new ParseException("expected " ~ what ~ " but found '" ~ peek().text ~ "'", peek().line);
        return advance();
    }

    void parseClause() @safe
    {
        VarScope scp;
        if (peek().kind == TokenKind.queryMark)
        {
            advance();
            auto atom = parseAtom(scp);
            expect(TokenKind.dot, "'.'");
            program.queries ~= Query(atom, scp.count);
            return;
        }
        auto head = parseAtom(scp);
        Literal[] body;
        if (peek().kind == TokenKind.neck)
        {
            advance();
            body ~= parseLiteral(scp);
            while (peek().kind == TokenKind.comma)
            {
                advance();
                body ~= parseLiteral(scp);
            }
        }
        expect(TokenKind.dot, "'.'");
        program.rules ~= Rule(head, body, scp.count);
    }

    Atom parseAtom(ref VarScope scp) @safe
    {
        auto name = expect(TokenKind.identifier, "a predicate name");
        expect(TokenKind.lparen, "'('");
        Term[] args;
        args ~= parseTerm(scp);
        while (peek().kind == TokenKind.comma)
        {
            advance();
            args ~= parseTerm(scp);
        }
        expect(TokenKind.rparen, "')'");
        return Atom(program.internPredicate(name.text, cast(uint) args.length), args);
    }

    Term parseTerm(ref VarScope scp) @safe
    {
        auto t = advance();
        switch (t.kind)
        {
        case TokenKind.identifier:
            return Term.constant(program.internIdentifier(t.text));
        case TokenKind.integer:
            return Term.constant(program.internInteger(t.value));
        case TokenKind.variable:
            return Term.variable(scp.slot(t.text));
        case TokenKind.anonymous:
            return Term.variable(scp.fresh());
        default:
            throw new ParseException("expected a term but found '" ~ t.text ~ "'", t.line);
        }
    }

    Literal parseLiteral(ref VarScope scp) @safe
    {
        Literal lit;
        if (peek().kind == TokenKind.not)
        {
            advance();
            lit.kind = LiteralKind.negative;
            lit.atom = parseAtom(scp);
        }
        else if (peek().kind == TokenKind.identifier && peek(1).kind == TokenKind.lparen)
        {
            lit.kind = LiteralKind.positive;
            lit.atom = parseAtom(scp);
        }
        else
        {
            lit.kind = LiteralKind.comparison;
            lit.lhs = parseTerm(scp);
            auto opTok = advance();
            switch (opTok.kind)
            {
            case TokenKind.lt:
                lit.op = CmpOp.lt;
                break;
            case TokenKind.le:
                lit.op = CmpOp.le;
                break;
            case TokenKind.gt:
                lit.op = CmpOp.gt;
                break;
            case TokenKind.ge:
                lit.op = CmpOp.ge;
                break;
            case TokenKind.eq:
                lit.op = CmpOp.eq;
                break;
            case TokenKind.ne:
                lit.op = CmpOp.ne;
                break;
            default:
                throw new ParseException("expected a comparison operator but found '"
                        ~ opTok.text ~ "'", opTok.line);
            }
            lit.rhs = parseTerm(scp);
        }
        return lit;
    }
}
