/**
 * The reader: text to datums.
 *
 * A recursive-descent parser for the lexical syntax in the specification:
 * integers of any length, booleans, strings with `\"` `\\` `\n` `\t` escapes,
 * symbols, lists (including dotted pairs), `'x` quotation and `;` comments.
 */
module scheme.reader;

import scheme.bignum : BigNum;
import scheme.numeric : fromBig;
import scheme.value;

/// Reads successive datums from a source string.
struct Reader
{
    private string src;
    private size_t pos;
    private SymbolTable symbols;

    /// Start reading `source`, interning symbols in `symbols`.
    this(string source, SymbolTable symbols)
    {
        this.src = source;
        this.symbols = symbols;
    }

    /// Read the next datum into `datum`; returns false at end of input.
    bool read(out Value datum)
    {
        skipTrivia();
        if (pos >= src.length)
            return false;
        datum = readDatum();
        return true;
    }

    private static bool isSpace(char c) pure nothrow @nogc @safe
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    }

    private static bool isDelimiter(char c) pure nothrow @nogc @safe
    {
        return isSpace(c) || c == '(' || c == ')' || c == '\'' || c == '"' || c == ';';
    }

    private void skipTrivia()
    {
        while (pos < src.length)
        {
            char c = src[pos];
            if (isSpace(c))
                ++pos;
            else if (c == ';')
            {
                while (pos < src.length && src[pos] != '\n')
                    ++pos;
            }
            else
                break;
        }
    }

    private Value readDatum()
    {
        skipTrivia();
        if (pos >= src.length)
            throw new SyntaxError("unexpected end of input");
        char c = src[pos];
        switch (c)
        {
        case '(':
            ++pos;
            return readListTail();
        case ')':
            throw new SyntaxError("unexpected ')'");
        case '\'':
            ++pos;
            auto quoted = readDatum();
            return Value.cons(Value.fromSymbol(symbols.quoteSym), Value.cons(quoted, Value.nil()));
        case '"':
            return readString();
        default:
            return readAtom();
        }
    }

    private Value readListTail()
    {
        Value head = Value.nil();
        Pair last = null;
        for (;;)
        {
            skipTrivia();
            if (pos >= src.length)
                throw new SyntaxError("unterminated list");
            char c = src[pos];
            if (c == ')')
            {
                ++pos;
                return head;
            }
            if (c == '.' && (pos + 1 >= src.length || isDelimiter(src[pos + 1])))
            {
                ++pos;
                if (last is null)
                    throw new SyntaxError("'.' at start of list");
                last.cdr = readDatum();
                skipTrivia();
                if (pos >= src.length || src[pos] != ')')
                    throw new SyntaxError("expected ')' after dotted tail");
                ++pos;
                return head;
            }
            auto cell = Value.cons(readDatum(), Value.nil());
            if (last is null)
                head = cell;
            else
                last.cdr = cell;
            last = cell.pair;
        }
    }

    private Value readString()
    {
        ++pos; // opening quote
        char[] buf;
        for (;;)
        {
            if (pos >= src.length)
                throw new SyntaxError("unterminated string");
            char c = src[pos++];
            if (c == '"')
                break;
            if (c == '\\' && pos < src.length)
            {
                char e = src[pos++];
                switch (e)
                {
                case 'n':
                    buf ~= '\n';
                    break;
                case 't':
                    buf ~= '\t';
                    break;
                default:
                    buf ~= e; // \" and \\ (and anything else) stand for themselves
                    break;
                }
            }
            else
                buf ~= c;
        }
        return Value.fromString(buf.idup);
    }

    private Value readAtom()
    {
        size_t start = pos;
        while (pos < src.length && !isDelimiter(src[pos]))
            ++pos;
        string tok = src[start .. pos];
        if (tok == "#t")
            return Value.fromBool(true);
        if (tok == "#f")
            return Value.fromBool(false);
        if (isIntegerToken(tok))
            return parseInteger(tok);
        return Value.fromSymbol(symbols.intern(tok));
    }

    private static bool isIntegerToken(string tok) pure nothrow @nogc @safe
    {
        size_t i = 0;
        if (tok[0] == '+' || tok[0] == '-')
            i = 1;
        if (i == tok.length)
            return false;
        foreach (c; tok[i .. $])
            if (c < '0' || c > '9')
                return false;
        return true;
    }

    private static Value parseInteger(string tok)
    {
        bool neg = tok[0] == '-';
        string digits = (tok[0] == '+' || neg) ? tok[1 .. $] : tok;
        if (digits.length <= 18)
        {
            long n = 0;
            foreach (c; digits)
                n = n * 10 + (c - '0');
            return Value.fromInt(neg ? -n : n);
        }
        return fromBig(BigNum.parse(digits, neg));
    }
}

version (unittest)
{
    import scheme.printer : toWriteString;

    private string roundTrip(string src)
    {
        auto syms = new SymbolTable;
        auto r = Reader(src, syms);
        Value v;
        string result;
        while (r.read(v))
        {
            if (result.length)
                result ~= " ";
            result ~= toWriteString(v);
        }
        return result;
    }
}

unittest
{
    assert(roundTrip("") == "");
    assert(roundTrip("  ; just a comment\n") == "");
    assert(roundTrip("42 -7 +5 007 -0") == "42 -7 5 7 0");
    assert(roundTrip("+ - ... set! list->string <= a.b 1+ -x") == "+ - ... set! list->string <= a.b 1+ -x");
    assert(roundTrip("#t #f") == "#t #f");
    assert(roundTrip("(1 2 . 3)") == "(1 2 . 3)");
    assert(roundTrip("(1 . (2 . (3 . ())))") == "(1 2 3)");
    assert(roundTrip("()") == "()");
    assert(roundTrip("'x") == "(quote x)");
    assert(roundTrip("''(a b)") == "(quote (quote (a b)))");
    assert(roundTrip("(a;comment\n b)") == "(a b)");
    assert(roundTrip("(a'b)") == "(a (quote b))");
    assert(roundTrip("123456789012345678901234567890") == "123456789012345678901234567890");
    assert(roundTrip("-123456789012345678901234567890") == "-123456789012345678901234567890");
    assert(roundTrip("123456789012345678") == "123456789012345678");
    assert(roundTrip("9223372036854775808") == "9223372036854775808");
}

unittest
{
    auto syms = new SymbolTable;
    auto r = Reader("\"a\\\"b\\\\c\\nd\\te\nf\"", syms);
    Value v;
    assert(r.read(v));
    assert(v.kind == Kind.string);
    assert(v.str.s == "a\"b\\c\nd\te\nf");
    assert(!r.read(v));
}

unittest
{
    auto syms = new SymbolTable;
    auto r = Reader("foo foo Foo", syms);
    Value a, b, c;
    r.read(a);
    r.read(b);
    r.read(c);
    assert(a.sym is b.sym);
    assert(a.sym !is c.sym);
}
