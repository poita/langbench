/// Reader: turns program text into datums.
module scheme.reader;

import scheme.bignum : BigInt;
import scheme.numeric : normalize;
import scheme.symbols;
import scheme.value;

/// A recursive-descent reader over an in-memory source string.
struct Reader
{
    private string src;
    private size_t pos;
    private SymbolTable syms;
    private Value[] scratch; // shared element stack for list construction

    /// Read datums from `source`, interning symbols in `syms`.
    this(string source, SymbolTable syms)
    {
        this.src = source;
        this.syms = syms;
    }

    /// Read the next datum into `v`; false at end of input.
    bool next(out Value v)
    {
        skipSpace();
        while (pos < src.length && src[pos] == ')') // stray close paren: ignore
        {
            ++pos;
            skipSpace();
        }
        if (pos >= src.length)
            return false;
        v = readDatum();
        return true;
    }

    private static bool isSpace(char c)
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    }

    private static bool isDelim(char c)
    {
        return isSpace(c) || c == '(' || c == ')' || c == '\'' || c == '"' || c == ';';
    }

    private void skipSpace()
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
        skipSpace();
        if (pos >= src.length)
            return Value.nil;
        char c = src[pos];
        switch (c)
        {
        case '(':
            ++pos;
            return readList();
        case '\'':
            ++pos;
            return Value.cons(Value.symbol(Known.quote),
                    Value.cons(readDatum(), Value.nil));
        case '"':
            ++pos;
            return readString();
        default:
            return readAtom();
        }
    }

    private Value readList()
    {
        immutable size_t base = scratch.length;
        Value tail = Value.nil;
        for (;;)
        {
            skipSpace();
            if (pos >= src.length)
                break;
            char c = src[pos];
            if (c == ')')
            {
                ++pos;
                break;
            }
            if (c == '.' && (pos + 1 >= src.length || isDelim(src[pos + 1])))
            {
                ++pos;
                tail = readDatum();
                skipSpace();
                if (pos < src.length && src[pos] == ')')
                    ++pos;
                break;
            }
            Value d = readDatum();
            scratch ~= d;
        }
        Value r = listFrom(scratch[base .. $], tail);
        scratch.length = base;
        return r;
    }

    private Value readString()
    {
        size_t start = pos;
        // fast path: no escapes
        while (pos < src.length && src[pos] != '"' && src[pos] != '\\')
            ++pos;
        if (pos < src.length && src[pos] == '"')
        {
            string s = src[start .. pos];
            ++pos;
            return Value.str(s);
        }
        char[] buf = src[start .. pos].dup;
        while (pos < src.length)
        {
            char c = src[pos++];
            if (c == '"')
                break;
            if (c == '\\' && pos < src.length)
            {
                char e = src[pos++];
                switch (e)
                {
                case 'n': buf ~= '\n'; break;
                case 't': buf ~= '\t'; break;
                default: buf ~= e; break;
                }
            }
            else
                buf ~= c;
        }
        return Value.str(cast(string) buf);
    }

    private Value readAtom()
    {
        size_t start = pos;
        while (pos < src.length && !isDelim(src[pos]))
            ++pos;
        string tok = src[start .. pos];
        if (tok == "#t")
            return Value.true_;
        if (tok == "#f")
            return Value.false_;
        // integer?
        size_t k = 0;
        bool neg = false;
        if (tok[0] == '+' || tok[0] == '-')
        {
            neg = tok[0] == '-';
            k = 1;
        }
        if (k < tok.length)
        {
            bool digits = true;
            foreach (ch; tok[k .. $])
                if (ch < '0' || ch > '9')
                {
                    digits = false;
                    break;
                }
            if (digits)
                return parseInteger(tok[k .. $], neg);
        }
        return Value.symbol(syms.intern(tok));
    }

    private static Value parseInteger(string digits, bool neg)
    {
        if (digits.length <= 18)
        {
            long v = 0;
            foreach (ch; digits)
                v = v * 10 + (ch - '0');
            return Value.fixnum(neg ? -v : v);
        }
        return normalize(BigInt.parseDecimal(digits, neg));
    }
}
