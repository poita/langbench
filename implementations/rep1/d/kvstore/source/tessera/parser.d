/// Parser for command lines (recursive descent over the token stream).
module tessera.parser;

import tessera.ast;
import tessera.constants;
import tessera.errors;
import tessera.lexer;
import tessera.value;

/// Parse one command line. Throws `TesseraException` with the error kind
/// the specification assigns to the first problem in source order.
Command parseCommand(string line) pure @safe
{
    auto toks = tokenize(line);
    if (toks.length == 0 || toks[0].kind != TokenKind.word)
        fail(ErrorKind.syntax);
    auto p = Parser(toks, 1);
    Command cmd;
    switch (toks[0].text)
    {
    case "begin": cmd.kind = CommandKind.begin; break;
    case "commit": cmd.kind = CommandKind.commit; break;
    case "rollback": cmd.kind = CommandKind.rollback; break;
    case "checkpoint": cmd.kind = CommandKind.checkpoint; break;
    case "stat": cmd.kind = CommandKind.stat; break;
    case "indexes": cmd.kind = CommandKind.indexes; break;
    case "put":
        cmd.kind = CommandKind.put;
        cmd.key = p.takeKey();
        cmd.value = p.parseValue(1);
        break;
    case "get":
        cmd.kind = CommandKind.get;
        cmd.key = p.takeKey();
        break;
    case "delete":
        cmd.kind = CommandKind.delete_;
        cmd.key = p.takeKey();
        break;
    case "update":
        cmd.kind = CommandKind.update;
        cmd.key = p.takeKey();
        cmd.path = p.takePath();
        cmd.value = p.parseValue(1);
        break;
    case "unset":
        cmd.kind = CommandKind.unset;
        cmd.key = p.takeKey();
        cmd.path = p.takePath();
        break;
    case "scan":
        cmd.kind = CommandKind.scan;
        cmd.scan = p.parseScanOptions();
        break;
    case "find":
        cmd.kind = CommandKind.find;
        cmd.pred = p.parseDisjunction();
        if (p.peekWord("limit"))
        {
            p.pos++;
            cmd.hasLimit = true;
            cmd.limit = p.takeLimit();
        }
        break;
    case "create":
        cmd.kind = CommandKind.createIndex;
        p.expectWord("index");
        cmd.path = p.takePath();
        break;
    case "drop":
        cmd.kind = CommandKind.dropIndex;
        p.expectWord("index");
        cmd.path = p.takePath();
        break;
    default:
        fail(ErrorKind.unknownCommand);
    }
    if (!p.atEnd)
        fail(ErrorKind.syntax);
    return cmd;
}

private struct Parser
{
    Token[] toks;
    size_t pos;

    bool atEnd() const pure nothrow @nogc @safe { return pos >= toks.length; }

    bool peekPunct(char c) const pure nothrow @nogc @safe
    {
        return pos < toks.length && toks[pos].isPunct(c);
    }

    bool peekWord(string w) const pure nothrow @nogc @safe
    {
        return pos < toks.length && toks[pos].isWord(w);
    }

    void expectWord(string w) pure @safe
    {
        if (!peekWord(w))
            fail(ErrorKind.syntax);
        pos++;
    }

    void expectPunct(char c) pure @safe
    {
        if (!peekPunct(c))
            fail(ErrorKind.syntax);
        pos++;
    }

    /// Consume a string token and resolve its value.
    string takeString() pure @safe
    {
        if (atEnd || toks[pos].kind != TokenKind.string_)
            fail(ErrorKind.syntax);
        auto t = &toks[pos++];
        if (t.badUtf8)
            fail(ErrorKind.badUtf8);
        return t.strValue;
    }

    string takeKey() pure @safe
    {
        auto s = takeString();
        if (s.length < 1 || s.length > maxKey)
            fail(ErrorKind.badKey);
        return s;
    }

    long takeInt() pure @safe
    {
        if (atEnd || toks[pos].kind != TokenKind.integer)
            fail(ErrorKind.syntax);
        auto t = &toks[pos++];
        if (t.intOverflow)
            fail(ErrorKind.intRange);
        return t.intValue;
    }

    long takeLimit() pure @safe
    {
        immutable n = takeInt();
        if (n < 0 || n > maxLimit)
            fail(ErrorKind.syntax);
        return n;
    }

    string[] takePath() pure @safe
    {
        string[] segs;
        size_t textLen = 0;
        while (true)
        {
            if (atEnd || toks[pos].kind != TokenKind.word)
                fail(ErrorKind.syntax);
            auto seg = toks[pos++].text;
            textLen += (segs.length ? 1 : 0) + seg.length;
            segs ~= seg;
            if (segs.length > maxPathSegments || textLen > maxPath)
                fail(ErrorKind.badPath);
            if (peekPunct('.'))
                pos++;
            else
                break;
        }
        return segs;
    }

    ScanOptions parseScanOptions() pure @safe
    {
        ScanOptions o;
        while (!atEnd)
        {
            if (toks[pos].kind != TokenKind.word)
                fail(ErrorKind.syntax);
            switch (toks[pos].text)
            {
            case "from":
                if (o.hasFrom)
                    fail(ErrorKind.syntax);
                pos++;
                o.from = takeString();
                o.hasFrom = true;
                break;
            case "to":
                if (o.hasTo)
                    fail(ErrorKind.syntax);
                pos++;
                o.to = takeString();
                o.hasTo = true;
                break;
            case "limit":
                if (o.hasLimit)
                    fail(ErrorKind.syntax);
                pos++;
                o.limit = takeLimit();
                o.hasLimit = true;
                break;
            case "reverse":
                if (o.reverse)
                    fail(ErrorKind.syntax);
                pos++;
                o.reverse = true;
                break;
            case "keys":
                if (o.keysOnly)
                    fail(ErrorKind.syntax);
                pos++;
                o.keysOnly = true;
                break;
            default:
                fail(ErrorKind.syntax);
            }
        }
        return o;
    }

    /// Parse a value at the given nesting level (the whole literal is level 1).
    Value parseValue(int level) pure @safe
    {
        if (level > maxDepth)
            fail(ErrorKind.depth);
        if (atEnd)
            fail(ErrorKind.syntax);
        auto t = &toks[pos++];
        final switch (t.kind)
        {
        case TokenKind.word:
            switch (t.text)
            {
            case "null": return Value.nullValue();
            case "true": return Value.boolean(true);
            case "false": return Value.boolean(false);
            default: fail(ErrorKind.syntax);
            }
        case TokenKind.integer:
            if (t.intOverflow)
                fail(ErrorKind.intRange);
            return Value.integer(t.intValue);
        case TokenKind.string_:
            if (t.badUtf8)
                fail(ErrorKind.badUtf8);
            return Value.string_(t.strValue);
        case TokenKind.punct:
            if (t.text[0] == '[')
                return parseList(level);
            if (t.text[0] == '{')
                return parseObject(level);
            fail(ErrorKind.syntax);
        case TokenKind.op:
            fail(ErrorKind.syntax);
        }
    }

    Value parseList(int level) pure @safe
    {
        Value[] elems;
        if (peekPunct(']'))
        {
            pos++;
            return Value.list(elems);
        }
        while (true)
        {
            elems ~= parseValue(level + 1);
            if (atEnd)
                fail(ErrorKind.syntax);
            auto t = &toks[pos++];
            if (t.isPunct(','))
                continue;
            if (t.isPunct(']'))
                break;
            fail(ErrorKind.syntax);
        }
        return Value.list(elems);
    }

    Value parseObject(int level) pure @safe
    {
        string[] fnames;
        Value[] fvals;
        if (peekPunct('}'))
        {
            pos++;
            return Value.object(fnames, fvals);
        }
        bool[string] seen;
        while (true)
        {
            if (atEnd)
                fail(ErrorKind.syntax);
            string name;
            auto t = &toks[pos++];
            if (t.kind == TokenKind.string_)
            {
                if (t.badUtf8)
                    fail(ErrorKind.badUtf8);
                name = t.strValue;
            }
            else if (t.kind == TokenKind.word)
                name = t.text;
            else
                fail(ErrorKind.syntax);
            if (name in seen)
                fail(ErrorKind.dupField);
            seen[name] = true;
            expectPunct(':');
            fnames ~= name;
            fvals ~= parseValue(level + 1);
            if (atEnd)
                fail(ErrorKind.syntax);
            auto s = &toks[pos++];
            if (s.isPunct(','))
                continue;
            if (s.isPunct('}'))
                break;
            fail(ErrorKind.syntax);
        }
        return Value.object(fnames, fvals);
    }

    // ------------------------------------------------------------ predicates

    Pred parseDisjunction() pure @safe
    {
        auto lhs = parseConjunction();
        while (peekWord("or"))
        {
            pos++;
            auto rhs = parseConjunction();
            auto n = new Pred(PredKind.or);
            n.kids = [lhs, rhs];
            lhs = n;
        }
        return lhs;
    }

    Pred parseConjunction() pure @safe
    {
        auto lhs = parseTerm();
        while (peekWord("and"))
        {
            pos++;
            auto rhs = parseTerm();
            auto n = new Pred(PredKind.and);
            n.kids = [lhs, rhs];
            lhs = n;
        }
        return lhs;
    }

    Pred parseTerm() pure @safe
    {
        if (atEnd)
            fail(ErrorKind.syntax);
        auto t = &toks[pos];
        if (t.isPunct('('))
        {
            pos++;
            auto p = parseDisjunction();
            expectPunct(')');
            return p;
        }
        if (t.kind != TokenKind.word)
            fail(ErrorKind.syntax);
        immutable nextIsParen = pos + 1 < toks.length && toks[pos + 1].isPunct('(');
        immutable nextIsWord = pos + 1 < toks.length && toks[pos + 1].kind == TokenKind.word;
        if (t.text == "not" && nextIsParen)
        {
            pos += 2;
            auto inner = parseDisjunction();
            expectPunct(')');
            auto n = new Pred(PredKind.not);
            n.kids = [inner];
            return n;
        }
        if (t.text == "exists" && nextIsWord)
        {
            pos++;
            auto n = new Pred(PredKind.exists);
            n.path = takePath();
            return n;
        }
        if (t.text == "missing" && nextIsWord)
        {
            pos++;
            auto n = new Pred(PredKind.missing);
            n.path = takePath();
            return n;
        }
        auto n = new Pred(PredKind.compare);
        n.path = takePath();
        if (atEnd || toks[pos].kind != TokenKind.op)
            fail(ErrorKind.syntax);
        n.op = toks[pos++].op;
        n.rhs = parseValue(1);
        return n;
    }
}
