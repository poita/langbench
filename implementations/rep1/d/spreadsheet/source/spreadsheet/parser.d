/// Recursive-descent parser for formulas, producing a resolved `Formula`.
module spreadsheet.parser;

import spreadsheet.ast;
import spreadsheet.cellref;
import spreadsheet.numfmt : parseNumber;

/// Thrown for content that is not a valid formula, string or number.
class SyntaxError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Maps a cell position to the sheet's dense integer handle for that cell.
alias Resolver = uint delegate(CellRef) @safe nothrow;

/**
 * Parse a formula.
 *
 * Params:
 *   text    = the cell content including the leading `=`
 *   resolve = called for each valid reference (and each cell of each range,
 *             in row-major order) to obtain its handle
 * Throws: `SyntaxError` if `text` does not follow the grammar.
 */
Formula parseFormula(string text, scope Resolver resolve) @safe
{
    if (text.length == 0 || text[0] != '=')
        throw new SyntaxError("formula must start with '='");
    auto p = Parser(text, 1, resolve);
    p.f.root = p.parseCmp();
    p.skipSpaces();
    if (p.pos != text.length)
        throw new SyntaxError("unexpected trailing input in formula");
    if (p.f.invalid)
        return Formula(null, null, null, 0, true);
    return p.f;
}

private struct Parser
{
    string s;
    size_t pos;
    Resolver resolve;
    Formula f;

    this(string s, size_t pos, Resolver r) @safe
    {
        this.s = s;
        this.pos = pos;
        this.resolve = r;
    }

    void skipSpaces() @safe pure nothrow @nogc
    {
        while (pos < s.length && s[pos] == ' ')
            pos++;
    }

    char peek() @safe pure nothrow @nogc
    {
        skipSpaces();
        return pos < s.length ? s[pos] : '\0';
    }

    void expect(char c) @safe
    {
        if (peek() != c)
            throw new SyntaxError("expected '" ~ c ~ "' in formula");
        pos++;
    }

    uint add(Node n) @safe pure nothrow
    {
        f.nodes ~= n;
        return cast(uint)(f.nodes.length - 1);
    }

    uint addBinary(BinOp op, uint a, uint b) @safe pure nothrow
    {
        return add(Node(NodeKind.binary, op, a, b));
    }

    uint parseCmp() @safe
    {
        uint left = parseCat();
        for (;;)
        {
            BinOp op;
            char c = peek();
            char d = pos + 1 < s.length ? s[pos + 1] : '\0';
            if (c == '=')
            {
                op = BinOp.eq;
                pos += 1;
            }
            else if (c == '<' && d == '>')
            {
                op = BinOp.ne;
                pos += 2;
            }
            else if (c == '<' && d == '=')
            {
                op = BinOp.le;
                pos += 2;
            }
            else if (c == '<')
            {
                op = BinOp.lt;
                pos += 1;
            }
            else if (c == '>' && d == '=')
            {
                op = BinOp.ge;
                pos += 2;
            }
            else if (c == '>')
            {
                op = BinOp.gt;
                pos += 1;
            }
            else
                return left;
            uint right = parseCat();
            left = addBinary(op, left, right);
        }
    }

    uint parseCat() @safe
    {
        uint left = parseAdd();
        while (peek() == '&')
        {
            pos++;
            uint right = parseAdd();
            left = addBinary(BinOp.concat, left, right);
        }
        return left;
    }

    uint parseAdd() @safe
    {
        uint left = parseMul();
        for (;;)
        {
            char c = peek();
            if (c != '+' && c != '-')
                return left;
            pos++;
            uint right = parseMul();
            left = addBinary(c == '+' ? BinOp.add : BinOp.sub, left, right);
        }
    }

    uint parseMul() @safe
    {
        uint left = parseUnary();
        for (;;)
        {
            char c = peek();
            if (c != '*' && c != '/')
                return left;
            pos++;
            uint right = parseUnary();
            left = addBinary(c == '*' ? BinOp.mul : BinOp.div, left, right);
        }
    }

    uint parseUnary() @safe
    {
        if (peek() == '-')
        {
            pos++;
            uint operand = parseUnary();
            return add(Node(NodeKind.negate, 0, operand));
        }
        return parsePrimary();
    }

    uint parsePrimary() @safe
    {
        char c = peek();
        if (c >= '0' && c <= '9')
            return parseNumberToken();
        if (c == '"')
        {
            size_t start = ++pos;
            while (pos < s.length && s[pos] != '"')
                pos++;
            if (pos >= s.length)
                throw new SyntaxError("unterminated string in formula");
            Node n;
            n.kind = NodeKind.text;
            n.str = s[start .. pos];
            pos++;
            return add(n);
        }
        if (c == '(')
        {
            pos++;
            uint e = parseCmp();
            expect(')');
            return e;
        }
        if (c >= 'A' && c <= 'Z')
        {
            size_t start = pos;
            while (pos < s.length && s[pos] >= 'A' && s[pos] <= 'Z')
                pos++;
            if (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
            {
                while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
                    pos++;
                return makeRef(s[start .. pos]);
            }
            return parseCall(s[start .. pos]);
        }
        throw new SyntaxError("unexpected character in formula");
    }

    uint parseNumberToken() @safe
    {
        size_t start = pos;
        while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
            pos++;
        if (pos + 1 < s.length && s[pos] == '.' && s[pos + 1] >= '0' && s[pos + 1] <= '9')
        {
            pos++;
            while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
                pos++;
        }
        double d;
        if (!parseNumber(s[start .. pos], d))
            throw new SyntaxError("bad number in formula");
        Node n;
        n.kind = NodeKind.number;
        n.num = d;
        return add(n);
    }

    /// A reference node; an invalid token marks the whole formula `#REF!`.
    uint makeRef(string token) @safe
    {
        CellRef r;
        if (!tryParseCellRef(token, r))
        {
            f.invalid = true;
            return add(Node(NodeKind.number));
        }
        return add(Node(NodeKind.cell, 0, resolve(r)));
    }

    uint parseCall(string name) @safe
    {
        expect('(');
        if (name == "IF")
        {
            uint c = parseCmp();
            expect(',');
            uint a = parseCmp();
            expect(',');
            uint b = parseCmp();
            expect(')');
            return add(Node(NodeKind.conditional, 0, c, a, b));
        }
        AggOp op;
        switch (name)
        {
        case "SUM":   op = AggOp.sum; break;
        case "MIN":   op = AggOp.min; break;
        case "MAX":   op = AggOp.max; break;
        case "AVG":   op = AggOp.avg; break;
        case "COUNT": op = AggOp.count; break;
        default: throw new SyntaxError("unknown function " ~ name);
        }
        Arg[] mine;
        for (;;)
        {
            mine ~= parseArg();
            if (peek() == ',')
                pos++;
            else
                break;
        }
        expect(')');
        // Append contiguously only now: nested calls have finished.
        uint start = cast(uint) f.args.length;
        f.args ~= mine;
        return add(Node(NodeKind.aggregate, op, start, cast(uint) mine.length));
    }

    /// Scan a reference-shaped token at `pos` (letters then digits).
    string scanRefToken() @safe pure nothrow @nogc
    {
        size_t start = pos;
        size_t i = pos;
        while (i < s.length && s[i] >= 'A' && s[i] <= 'Z')
            i++;
        size_t letters = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (letters == start || i == letters)
            return null;
        return s[start .. i];
    }

    Arg parseArg() @safe
    {
        skipSpaces();
        string first = scanRefToken();
        if (first !is null && pos + first.length < s.length && s[pos + first.length] == ':')
        {
            pos += first.length + 1;
            string second = scanRefToken();
            if (second is null)
                throw new SyntaxError("bad range in formula");
            pos += second.length;
            return makeRange(first, second);
        }
        return Arg(false, parseCmp());
    }

    Arg makeRange(string t1, string t2) @safe
    {
        CellRef a, b;
        if (!tryParseCellRef(t1, a) || !tryParseCellRef(t2, b))
        {
            f.invalid = true;
            return Arg(false, add(Node(NodeKind.number)));
        }
        uint c1 = a.col < b.col ? a.col : b.col, c2 = a.col < b.col ? b.col : a.col;
        uint r1 = a.row < b.row ? a.row : b.row, r2 = a.row < b.row ? b.row : a.row;
        Arg arg;
        arg.isRange = true;
        arg.cellsStart = cast(uint) f.rangeCells.length;
        arg.cellsLen = (c2 - c1 + 1) * (r2 - r1 + 1);
        f.rangeCells.reserve(f.rangeCells.length + arg.cellsLen);
        foreach (r; r1 .. r2 + 1)
            foreach (c; c1 .. c2 + 1)
                f.rangeCells ~= resolve(CellRef(cast(ushort) c, cast(ushort) r));
        return arg;
    }
}
