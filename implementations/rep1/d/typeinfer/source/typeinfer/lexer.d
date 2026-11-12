/**
 * Lexical analysis.
 *
 * Turns program text into an array of $(LREF Token)s. Tokens refer back to the
 * source by byte offsets, so tokenising allocates only the token array.
 */
module typeinfer.lexer;

/// Kinds of token.
enum Tok : ubyte
{
    eof,        /// end of input
    error,      /// a character that is not part of the language
    integer,    /// decimal integer literal
    ident,      /// identifier
    kwLet, kwRec, kwIn, kwFun, kwIf, kwThen, kwElse, kwTrue, kwFalse,
    semiSemi,   /// `;;`
    arrow,      /// `->`
    colonColon, /// `::`
    le,         /// `<=`
    ge,         /// `>=`
    andAnd,     /// `&&`
    orOr,       /// `||`
    lParen, rParen, lBracket, rBracket,
    semi, comma, plus, minus, star, slash, eq, lt, gt,
}

/// A token: its kind and the half-open byte range `[start, end)` in the source.
struct Token
{
    Tok kind;
    uint start;
    uint end;
}

/// Thrown by the parser (not the lexer) when it meets a `Tok.error` token.
class SyntaxError : Exception
{
    /// Byte offset in the source at which the problem was detected.
    size_t offset;

    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) @safe nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

private Tok keyword(const(char)[] s) @safe nothrow @nogc
{
    switch (s)
    {
        case "let": return Tok.kwLet;
        case "rec": return Tok.kwRec;
        case "in": return Tok.kwIn;
        case "fun": return Tok.kwFun;
        case "if": return Tok.kwIf;
        case "then": return Tok.kwThen;
        case "else": return Tok.kwElse;
        case "true": return Tok.kwTrue;
        case "false": return Tok.kwFalse;
        default: return Tok.ident;
    }
}

/**
 * Splits `src` into tokens. The result always ends with a `Tok.eof` token.
 * An unrecognised character yields a `Tok.error` token and ends the scan
 * (followed by `Tok.eof`), so a syntax error is reported only when the parser
 * reaches it.
 */
Token[] tokenize(string src) @safe nothrow
{
    Token[] toks;
    toks.reserve(src.length / 3 + 2);
    size_t i = 0;
    immutable n = src.length;

    void add(Tok k, size_t s, size_t e) { toks ~= Token(k, cast(uint) s, cast(uint) e); }

    while (i < n)
    {
        immutable c = src[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            ++i;
        }
        else if (c >= '0' && c <= '9')
        {
            immutable s = i;
            while (i < n && src[i] >= '0' && src[i] <= '9') ++i;
            add(Tok.integer, s, i);
        }
        else if (c >= 'a' && c <= 'z')
        {
            immutable s = i;
            ++i;
            while (i < n)
            {
                immutable d = src[i];
                if ((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z')
                        || (d >= '0' && d <= '9') || d == '_')
                    ++i;
                else
                    break;
            }
            add(keyword(src[s .. i]), s, i);
        }
        else
        {
            immutable next = i + 1 < n ? src[i + 1] : '\0';
            Tok k = Tok.error;
            size_t len = 1;
            switch (c)
            {
                case ';': if (next == ';') { k = Tok.semiSemi; len = 2; } else k = Tok.semi; break;
                case '-': if (next == '>') { k = Tok.arrow; len = 2; } else k = Tok.minus; break;
                case ':': if (next == ':') { k = Tok.colonColon; len = 2; } break;
                case '<': if (next == '=') { k = Tok.le; len = 2; } else k = Tok.lt; break;
                case '>': if (next == '=') { k = Tok.ge; len = 2; } else k = Tok.gt; break;
                case '&': if (next == '&') { k = Tok.andAnd; len = 2; } break;
                case '|': if (next == '|') { k = Tok.orOr; len = 2; } break;
                case '(': k = Tok.lParen; break;
                case ')': k = Tok.rParen; break;
                case '[': k = Tok.lBracket; break;
                case ']': k = Tok.rBracket; break;
                case ',': k = Tok.comma; break;
                case '+': k = Tok.plus; break;
                case '*': k = Tok.star; break;
                case '/': k = Tok.slash; break;
                case '=': k = Tok.eq; break;
                default: break;
            }
            add(k, i, i + len);
            if (k == Tok.error)
            {
                i = n;
                break;
            }
            i += len;
        }
    }
    add(Tok.eof, n, n);
    return toks;
}

@safe nothrow unittest
{
    auto t = tokenize("let x1 = 12 ;; ->::<=>=&&||");
    Tok[] kinds;
    foreach (tk; t) kinds ~= tk.kind;
    assert(kinds == [Tok.kwLet, Tok.ident, Tok.eq, Tok.integer, Tok.semiSemi,
            Tok.arrow, Tok.colonColon, Tok.le, Tok.ge, Tok.andAnd, Tok.orOr, Tok.eof]);
}

@safe nothrow unittest
{
    // Keywords only match whole identifiers.
    auto t = tokenize("letx inx funny let");
    assert(t[0].kind == Tok.ident && t[1].kind == Tok.ident
            && t[2].kind == Tok.ident && t[3].kind == Tok.kwLet);
}

@safe nothrow unittest
{
    // Longest match: `;;` is one token, `; ;` is two, `-` followed by `>` is an arrow.
    auto t = tokenize(";;; ; ;a->b");
    assert(t[0].kind == Tok.semiSemi && t[1].kind == Tok.semi && t[2].kind == Tok.semi);
    assert(t[3].kind == Tok.semi && t[5].kind == Tok.arrow);
}

@safe nothrow unittest
{
    auto t = tokenize("1 $ 2");
    assert(t.length == 3 && t[1].kind == Tok.error && t[2].kind == Tok.eof);
    assert(tokenize("   \n\t").length == 1);
}
