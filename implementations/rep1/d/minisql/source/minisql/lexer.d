/// Tokenizer: turns SQL text into a flat array of tokens in one pass.
module minisql.lexer;

/// Token kinds. Keywords have their own kinds; everything that is not a
/// keyword but is spelled like a word is `ident`.
enum Tok : ubyte
{
    eof,
    ident,
    integer,
    string_,
    invalid, /// a character that cannot start any token
    unterminated, /// a string literal that is never closed (always the last token)
    semi,
    lparen,
    rparen,
    comma,
    dot,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    // reserved keywords
    kSelect,
    kFrom,
    kWhere,
    kAnd,
    kOr,
    kNot,
    kNull,
    kIs,
    kLike,
    kAs,
    kInsert,
    kInto,
    kValues,
    kDelete,
    kUpdate,
    kSet,
    kCreate,
    kTable,
    kInteger,
    kText,
    kInner,
    kJoin,
    kOn,
    kGroup,
    kBy,
    kHaving,
    kOrder,
    kAsc,
    kDesc,
    kLimit,
    kOffset,
    kLeft,
    kRight,
    kFull,
    kOuter,
    kCross,
    kNatural,
}

/// One lexical token.
struct Token
{
    /// What kind of token this is.
    Tok kind;
    /// For `ident`: the lower-cased name. For `string_`: the unescaped contents.
    string text;
    /// For `integer`: the value (saturating at `long.max`).
    long value;
}

private bool isWordStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isWordChar(char c) pure nothrow @nogc @safe
{
    return isWordStart(c) || (c >= '0' && c <= '9');
}

/// Looks a word up in the reserved-keyword table (case-insensitively, without
/// allocating). Returns `Tok.ident` when the word is not reserved.
Tok keywordKind(const(char)[] word) pure nothrow @nogc @safe
{
    if (word.length < 2 || word.length > 7)
        return Tok.ident;
    char[8] buf = void;
    foreach (i, c; word)
        buf[i] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    switch (buf[0 .. word.length])
    {
    case "select":
        return Tok.kSelect;
    case "from":
        return Tok.kFrom;
    case "where":
        return Tok.kWhere;
    case "and":
        return Tok.kAnd;
    case "or":
        return Tok.kOr;
    case "not":
        return Tok.kNot;
    case "null":
        return Tok.kNull;
    case "is":
        return Tok.kIs;
    case "like":
        return Tok.kLike;
    case "as":
        return Tok.kAs;
    case "insert":
        return Tok.kInsert;
    case "into":
        return Tok.kInto;
    case "values":
        return Tok.kValues;
    case "delete":
        return Tok.kDelete;
    case "update":
        return Tok.kUpdate;
    case "set":
        return Tok.kSet;
    case "create":
        return Tok.kCreate;
    case "table":
        return Tok.kTable;
    case "integer":
        return Tok.kInteger;
    case "text":
        return Tok.kText;
    case "inner":
        return Tok.kInner;
    case "join":
        return Tok.kJoin;
    case "on":
        return Tok.kOn;
    case "group":
        return Tok.kGroup;
    case "by":
        return Tok.kBy;
    case "having":
        return Tok.kHaving;
    case "order":
        return Tok.kOrder;
    case "asc":
        return Tok.kAsc;
    case "desc":
        return Tok.kDesc;
    case "limit":
        return Tok.kLimit;
    case "offset":
        return Tok.kOffset;
    case "left":
        return Tok.kLeft;
    case "right":
        return Tok.kRight;
    case "full":
        return Tok.kFull;
    case "outer":
        return Tok.kOuter;
    case "cross":
        return Tok.kCross;
    case "natural":
        return Tok.kNatural;
    default:
        return Tok.ident;
    }
}

private string lowerWord(string w) pure nothrow @trusted
{
    bool upper = false;
    foreach (c; w)
        if (c >= 'A' && c <= 'Z')
        {
            upper = true;
            break;
        }
    if (!upper)
        return w;
    auto r = new char[w.length];
    foreach (i, c; w)
        r[i] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return cast(string) r;
}

/// Splits `src` into tokens. Comments and whitespace are dropped. Characters
/// that cannot start a token become `Tok.invalid` tokens (so that the
/// statement containing them can be reported as a syntax error while later
/// statements still run). An unclosed string literal yields a final
/// `Tok.unterminated` token and stops the scan.
Token[] tokenize(string src) pure nothrow @safe
{
    Token[] toks;
    toks.reserve(src.length / 4 + 4);
    size_t i = 0;
    immutable n = src.length;

    void put(Tok k) @safe nothrow pure
    {
        toks ~= Token(k, null, 0);
    }

    while (i < n)
    {
        immutable c = src[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v')
        {
            i++;
            continue;
        }
        if (c == '-' && i + 1 < n && src[i + 1] == '-')
        {
            i += 2;
            while (i < n && src[i] != '\n')
                i++;
            continue;
        }
        if (isWordStart(c))
        {
            immutable start = i;
            while (i < n && isWordChar(src[i]))
                i++;
            immutable word = src[start .. i];
            immutable k = keywordKind(word);
            toks ~= Token(k, k == Tok.ident ? lowerWord(word) : null, 0);
            continue;
        }
        if (c >= '0' && c <= '9')
        {
            long v = 0;
            while (i < n && src[i] >= '0' && src[i] <= '9')
            {
                immutable d = src[i] - '0';
                v = v > (long.max - d) / 10 ? long.max : v * 10 + d;
                i++;
            }
            toks ~= Token(Tok.integer, null, v);
            continue;
        }
        if (c == '\'')
        {
            size_t j = i + 1;
            bool escaped = false;
            bool closed = false;
            while (j < n)
            {
                if (src[j] == '\'')
                {
                    if (j + 1 < n && src[j + 1] == '\'')
                    {
                        escaped = true;
                        j += 2;
                        continue;
                    }
                    closed = true;
                    break;
                }
                j++;
            }
            if (!closed)
            {
                put(Tok.unterminated);
                return toks;
            }
            string body_ = src[i + 1 .. j];
            if (escaped)
            {
                char[] r;
                r.reserve(body_.length);
                for (size_t k = 0; k < body_.length; k++)
                {
                    r ~= body_[k];
                    if (body_[k] == '\'')
                        k++; // skip the second quote of the pair
                }
                body_ = (() @trusted => cast(string) r)();
            }
            toks ~= Token(Tok.string_, body_, 0);
            i = j + 1;
            continue;
        }
        i++;
        switch (c)
        {
        case ';':
            put(Tok.semi);
            break;
        case '(':
            put(Tok.lparen);
            break;
        case ')':
            put(Tok.rparen);
            break;
        case ',':
            put(Tok.comma);
            break;
        case '.':
            put(Tok.dot);
            break;
        case '+':
            put(Tok.plus);
            break;
        case '-':
            put(Tok.minus);
            break;
        case '*':
            put(Tok.star);
            break;
        case '/':
            put(Tok.slash);
            break;
        case '%':
            put(Tok.percent);
            break;
        case '=':
            if (i < n && src[i] == '=')
                i++;
            put(Tok.eq);
            break;
        case '!':
            if (i < n && src[i] == '=')
            {
                i++;
                put(Tok.ne);
            }
            else
                put(Tok.invalid);
            break;
        case '<':
            if (i < n && src[i] == '=')
            {
                i++;
                put(Tok.le);
            }
            else if (i < n && src[i] == '>')
            {
                i++;
                put(Tok.ne);
            }
            else
                put(Tok.lt);
            break;
        case '>':
            if (i < n && src[i] == '=')
            {
                i++;
                put(Tok.ge);
            }
            else
                put(Tok.gt);
            break;
        default:
            put(Tok.invalid);
            break;
        }
    }
    return toks;
}

/// Splits a token array into statements on `semi` tokens. Empty statements are
/// dropped. Each returned slice excludes its terminating semicolon.
const(Token)[][] splitStatements(const(Token)[] toks) pure nothrow @safe
{
    const(Token)[][] result;
    size_t start = 0;
    foreach (i, t; toks)
    {
        if (t.kind == Tok.semi)
        {
            if (i > start)
                result ~= toks[start .. i];
            start = i + 1;
        }
    }
    if (start < toks.length)
        result ~= toks[start .. $];
    return result;
}
