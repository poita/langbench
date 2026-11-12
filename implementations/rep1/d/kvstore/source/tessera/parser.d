/// Parsing of commands, value literals, field paths and predicates
/// (SPEC §6, §17.1, §18.2).
module tessera.parser;

import tessera.constants;
import tessera.errors;
import tessera.lexer;
import tessera.query;
import tessera.value;

/// The fifteen commands.
enum Cmd
{
    begin,
    commit,
    rollback,
    checkpoint,
    stat,
    indexes,
    put,
    get,
    delete_,
    update,
    unset,
    scan,
    find,
    createIndex,
    dropIndex,
}

/// Options of `scan`.
struct ScanOptions
{
    bool hasFrom, hasTo, hasLimit, reverse, keysOnly;
    string from, to;
    long limit;
}

/// A fully parsed command line.
struct Command
{
    Cmd cmd;
    /// Key argument of `put`, `get`, `delete`, `update`, `unset`.
    string key;
    /// Document of `put`, value of `update`.
    Value value;
    /// Field path of `update`, `unset`, `create index`, `drop index`.
    string[] path;
    /// Text of `path`.
    string pathText;
    ///
    ScanOptions scan;
    /// Predicate of `find`.
    Pred pred;
    /// `find`'s limit, `-1` when absent.
    long limit = -1;
}

/// Parse one command line. Throws `TesseraError` with the first problem in
/// source order (SPEC §18.2 stages 1-3).
Command parseCommand(string line) @safe
{
    auto toks = lex(line);
    if (toks.length == 0 || toks[0].kind != Tok.word)
        fail(ErrorKind.syntax);
    auto p = Parser(toks, 1);
    Command c;
    switch (toks[0].text)
    {
    case "begin":
        c.cmd = Cmd.begin;
        break;
    case "commit":
        c.cmd = Cmd.commit;
        break;
    case "rollback":
        c.cmd = Cmd.rollback;
        break;
    case "checkpoint":
        c.cmd = Cmd.checkpoint;
        break;
    case "stat":
        c.cmd = Cmd.stat;
        break;
    case "indexes":
        c.cmd = Cmd.indexes;
        break;
    case "put":
        c.cmd = Cmd.put;
        c.key = p.parseKey();
        c.value = p.parseValue(1);
        break;
    case "get":
        c.cmd = Cmd.get;
        c.key = p.parseKey();
        break;
    case "delete":
        c.cmd = Cmd.delete_;
        c.key = p.parseKey();
        break;
    case "update":
        c.cmd = Cmd.update;
        c.key = p.parseKey();
        p.parsePath(c.path, c.pathText);
        c.value = p.parseValue(1);
        break;
    case "unset":
        c.cmd = Cmd.unset;
        c.key = p.parseKey();
        p.parsePath(c.path, c.pathText);
        break;
    case "scan":
        c.cmd = Cmd.scan;
        c.scan = p.parseScanOptions();
        break;
    case "find":
        c.cmd = Cmd.find;
        c.pred = p.parseOr();
        if (p.peekWord("limit"))
        {
            p.pos++;
            c.limit = p.parseLimit();
        }
        break;
    case "create":
        c.cmd = Cmd.createIndex;
        p.expectWord("index");
        p.parsePath(c.path, c.pathText);
        break;
    case "drop":
        c.cmd = Cmd.dropIndex;
        p.expectWord("index");
        p.parsePath(c.path, c.pathText);
        break;
    default:
        fail(ErrorKind.unknownCommand);
    }
    if (p.pos != toks.length)
        fail(ErrorKind.syntax);
    return c;
}

private struct Parser
{
    Token[] toks;
    size_t pos;

    bool atEnd() const @safe pure nothrow @nogc
    {
        return pos >= toks.length;
    }

    /// The token `ahead` positions from the current one; a word-less dummy
    /// when past the end.
    Token peek(size_t ahead = 0) const @safe pure nothrow @nogc
    {
        return pos + ahead < toks.length ? toks[pos + ahead] : Token(Tok.op, "");
    }

    bool peekWord(string w) const @safe pure nothrow @nogc
    {
        return !atEnd && toks[pos].isWord(w);
    }

    bool peekSym(string s, size_t ahead = 0) const @safe pure nothrow @nogc
    {
        return pos + ahead < toks.length && toks[pos + ahead].isSym(s);
    }

    void expectWord(string w) @safe pure
    {
        if (!peekWord(w))
            fail(ErrorKind.syntax);
        pos++;
    }

    void expectSym(string s) @safe pure
    {
        if (!peekSym(s))
            fail(ErrorKind.syntax);
        pos++;
    }

    /// A STRING token resolved to its text.
    string parseString() @safe pure
    {
        if (atEnd || toks[pos].kind != Tok.str)
            fail(ErrorKind.syntax);
        return unescape(toks[pos++].text);
    }

    /// A key argument: a string of 1..128 bytes.
    string parseKey() @safe pure
    {
        auto s = parseString();
        if (s.length == 0 || s.length > MAX_KEY)
            fail(ErrorKind.badKey);
        return s;
    }

    /// An INT token resolved to a 64-bit integer.
    long parseInt() @safe pure
    {
        if (atEnd || toks[pos].kind != Tok.int_)
            fail(ErrorKind.syntax);
        return resolveInt(toks[pos++].text);
    }

    /// A `limit` argument: an INT in 0..MAX_LIMIT.
    long parseLimit() @safe pure
    {
        immutable n = parseInt();
        if (n < 0 || n > MAX_LIMIT)
            fail(ErrorKind.syntax);
        return n;
    }

    /// A field path; limits are checked as each segment is consumed.
    void parsePath(ref string[] segments, ref string text) @safe pure
    {
        segments = null;
        text = null;
        while (true)
        {
            if (atEnd || toks[pos].kind != Tok.word)
                fail(ErrorKind.syntax);
            immutable seg = toks[pos++].text;
            segments ~= seg;
            text = text.length == 0 && segments.length == 1 ? seg : text ~ "." ~ seg;
            if (segments.length > MAX_PATH_SEGMENTS || text.length > MAX_PATH)
                fail(ErrorKind.badPath);
            if (peekSym("."))
                pos++;
            else
                return;
        }
    }

    /// A value literal at nesting level `level` (SPEC §6.3).
    Value parseValue(size_t level) @safe pure
    {
        if (atEnd)
            fail(ErrorKind.syntax);
        immutable t = toks[pos];
        switch (t.kind)
        {
        case Tok.word:
            pos++;
            if (t.text == "null")
                return Value.nul();
            if (t.text == "true")
                return Value.boolean(true);
            if (t.text == "false")
                return Value.boolean(false);
            fail(ErrorKind.syntax);
        case Tok.int_:
            pos++;
            return Value.integer(resolveInt(t.text));
        case Tok.str:
            pos++;
            return Value.text(unescape(t.text));
        case Tok.punct:
            if (t.text == "[")
                return parseList(level);
            if (t.text == "{")
                return parseObject(level);
            fail(ErrorKind.syntax);
        default:
            fail(ErrorKind.syntax);
        }
    }

    private Value parseList(size_t level) @safe pure
    {
        pos++; // [
        Value[] items;
        if (peekSym("]"))
        {
            pos++;
            return Value.list(items);
        }
        while (true)
        {
            if (level + 1 > MAX_DEPTH)
                fail(ErrorKind.depth);
            items ~= parseValue(level + 1);
            if (peekSym(","))
                pos++;
            else if (peekSym("]"))
            {
                pos++;
                return Value.list(items);
            }
            else
                fail(ErrorKind.syntax);
        }
    }

    private Value parseObject(size_t level) @safe pure
    {
        pos++; // {
        auto obj = Value.object();
        if (peekSym("}"))
        {
            pos++;
            return obj;
        }
        while (true)
        {
            if (atEnd || (toks[pos].kind != Tok.str && toks[pos].kind != Tok.word))
                fail(ErrorKind.syntax);
            immutable nt = toks[pos++];
            immutable name = nt.kind == Tok.str ? unescape(nt.text) : nt.text;
            if (obj.field(name) !is null)
                fail(ErrorKind.dupField);
            expectSym(":");
            if (level + 1 > MAX_DEPTH)
                fail(ErrorKind.depth);
            obj.insertField(name, parseValue(level + 1));
            if (peekSym(","))
                pos++;
            else if (peekSym("}"))
            {
                pos++;
                return obj;
            }
            else
                fail(ErrorKind.syntax);
        }
    }

    ScanOptions parseScanOptions() @safe pure
    {
        ScanOptions o;
        while (!atEnd && toks[pos].kind == Tok.word)
        {
            immutable w = toks[pos].text;
            switch (w)
            {
            case "from":
                if (o.hasFrom)
                    fail(ErrorKind.syntax);
                o.hasFrom = true;
                pos++;
                o.from = parseString();
                break;
            case "to":
                if (o.hasTo)
                    fail(ErrorKind.syntax);
                o.hasTo = true;
                pos++;
                o.to = parseString();
                break;
            case "limit":
                if (o.hasLimit)
                    fail(ErrorKind.syntax);
                o.hasLimit = true;
                pos++;
                o.limit = parseLimit();
                break;
            case "reverse":
                if (o.reverse)
                    fail(ErrorKind.syntax);
                o.reverse = true;
                pos++;
                break;
            case "keys":
                if (o.keysOnly)
                    fail(ErrorKind.syntax);
                o.keysOnly = true;
                pos++;
                break;
            default:
                fail(ErrorKind.syntax);
            }
        }
        return o;
    }

    // ------------------------------------------------------------ predicates

    Pred parseOr() @safe pure
    {
        auto lhs = parseAnd();
        while (peekWord("or"))
        {
            pos++;
            auto p = new Pred;
            p.kind = PredKind.or;
            p.lhs = lhs;
            p.rhs = parseAnd();
            lhs = p;
        }
        return lhs;
    }

    private Pred parseAnd() @safe pure
    {
        auto lhs = parseTerm();
        while (peekWord("and"))
        {
            pos++;
            auto p = new Pred;
            p.kind = PredKind.and;
            p.lhs = lhs;
            p.rhs = parseTerm();
            lhs = p;
        }
        return lhs;
    }

    private Pred parseTerm() @safe pure
    {
        if (atEnd)
            fail(ErrorKind.syntax);
        auto p = new Pred;
        if (peekSym("("))
        {
            pos++;
            auto inner = parseOr();
            expectSym(")");
            return inner;
        }
        if (peekWord("not") && peekSym("(", 1))
        {
            pos += 2;
            p.kind = PredKind.not;
            p.lhs = parseOr();
            expectSym(")");
            return p;
        }
        if ((peekWord("exists") || peekWord("missing")) && peek(1).kind == Tok.word)
        {
            p.kind = peekWord("exists") ? PredKind.exists : PredKind.missing;
            pos++;
            parsePath(p.path, p.pathText);
            return p;
        }
        if (toks[pos].kind != Tok.word)
            fail(ErrorKind.syntax);
        p.kind = PredKind.compare;
        parsePath(p.path, p.pathText);
        if (atEnd || toks[pos].kind != Tok.op)
            fail(ErrorKind.syntax);
        switch (toks[pos].text)
        {
        case "==":
            p.op = CmpOp.eq;
            break;
        case "!=":
            p.op = CmpOp.ne;
            break;
        case "<":
            p.op = CmpOp.lt;
            break;
        case "<=":
            p.op = CmpOp.le;
            break;
        case ">":
            p.op = CmpOp.gt;
            break;
        default:
            p.op = CmpOp.ge;
            break;
        }
        pos++;
        p.value = parseValue(1);
        return p;
    }
}

@safe unittest
{
    auto c = parseCommand(`put "a" {name:"ada", age: 36}`);
    assert(c.cmd == Cmd.put && c.key == "a");
    assert(renderToString(c.value) == `{"age":36,"name":"ada"}`);

    c = parseCommand(`update "a" x . y 1`);
    assert(c.pathText == "x.y" && c.path == ["x", "y"]);

    c = parseCommand(`scan limit 3 reverse keys from "a" to "b"`);
    assert(c.scan.hasLimit && c.scan.limit == 3 && c.scan.reverse && c.scan.keysOnly);
    assert(c.scan.from == "a" && c.scan.to == "b");

    c = parseCommand(`find age > 3 and not(name == "x") or exists a.b limit 2`);
    assert(c.pred.kind == PredKind.or && c.limit == 2);
    assert(c.pred.lhs.kind == PredKind.and);
}

@safe unittest
{
    static void expect(string line, ErrorKind k)
    {
        try
            parseCommand(line);
        catch (TesseraError e)
        {
            assert(e.kind == k, line);
            return;
        }
        assert(false, line);
    }

    expect(``, ErrorKind.syntax);
    expect(`"x"`, ErrorKind.syntax);
    expect(`PUT "a" 1`, ErrorKind.unknownCommand);
    expect(`frobnicate "\ud800"`, ErrorKind.unknownCommand);
    expect(`put "\ud800" 1`, ErrorKind.badUtf8);
    expect(`put 1 "x"`, ErrorKind.syntax);
    expect(`put "a" [1,]`, ErrorKind.syntax);
    expect(`put "a" {x:1,x}`, ErrorKind.dupField);
    expect(`put "a" {x:1,x 2}`, ErrorKind.dupField);
    expect(`get "a" "\ud800"`, ErrorKind.syntax);
    expect(`put "a" 1 99999999999999999999`, ErrorKind.syntax);
    expect(`put "" 1`, ErrorKind.badKey);
    expect(`scan limit -1`, ErrorKind.syntax);
    expect(`scan limit 1 limit 2`, ErrorKind.syntax);
    expect(`scan limit 99999999999999999999`, ErrorKind.intRange);
    expect(`scan limit 2147483648`, ErrorKind.syntax);
    expect(`unset "a" a.b.c.d.e.f.g.h.i.`, ErrorKind.badPath);
    expect(`unset "a" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .`, ErrorKind.badPath);
    expect(`find a ==`, ErrorKind.syntax);
    expect(`find a == 1 limit`, ErrorKind.syntax);
    expect(`find (a == 1`, ErrorKind.syntax);

    // depth: levels are checked before the next token is examined
    string rep(string s, size_t n) { string r; foreach (_; 0 .. n) r ~= s; return r; }
    parseCommand(`put "a" ` ~ rep("[", 32) ~ rep("]", 32));
    expect(`put "a" ` ~ rep("[", 32) ~ "1" ~ rep("]", 32), ErrorKind.depth);
    expect(`put "a" ` ~ rep("[", 32) ~ ")", ErrorKind.depth);
    expect(`put "a" ` ~ rep("[", 32), ErrorKind.depth);
    expect(`put "a" ` ~ rep("[", 30) ~ `{x:[[1]],x:1}`, ErrorKind.depth);
    expect(`put "a" ` ~ rep("[", 30) ~ `{x:1,x:[[1]]}`, ErrorKind.dupField);
}
