/**
 * One-pass lexer.
 *
 * Turns source text into an array of `Token`s. Keywords and symbols get their
 * own `Tok` kind; identifiers carry a dense integer id from an `Interner`;
 * integer literals carry no value.
 */
module typeinfer.lexer;

import typeinfer.errors;

/// Token kinds: one per keyword and per symbol.
enum Tok : ubyte
{
    eof, integer, ident,
    kwLet, kwRec, kwIn, kwFun, kwIf, kwThen, kwElse, kwTrue, kwFalse,
    semiSemi, arrow, colonColon, lessEq, greaterEq, andAnd, orOr,
    lparen, rparen, lbracket, rbracket, semi, comma,
    plus, minus, star, slash, eq, less, greater,
}

/// A lexical token.
struct Token
{
    /// Kind of the token.
    Tok kind;
    /// Interned name id for `Tok.ident`; otherwise 0.
    int id;
    /// Byte offset of the token in the source.
    uint pos;
}

/// Maps identifier text to dense integer ids (0, 1, 2, ...).
final class Interner
{
    private int[string] ids;
    private string[] table;

    /// Id of `name`, assigning the next free id when it is new.
    int intern(string name)
    {
        if (auto p = name in ids)
            return *p;
        immutable id = cast(int) table.length;
        ids[name] = id;
        table ~= name;
        return id;
    }

    /// The text of identifier `id`.
    string name(int id) const pure nothrow @safe @nogc { return table[id]; }

    /// Number of distinct names interned so far.
    size_t length() const pure nothrow @safe @nogc { return table.length; }
}

private Tok keywordKind(string s) pure nothrow @safe @nogc
{
    switch (s)
    {
    case "let":   return Tok.kwLet;
    case "rec":   return Tok.kwRec;
    case "in":    return Tok.kwIn;
    case "fun":   return Tok.kwFun;
    case "if":    return Tok.kwIf;
    case "then":  return Tok.kwThen;
    case "else":  return Tok.kwElse;
    case "true":  return Tok.kwTrue;
    case "false": return Tok.kwFalse;
    default:      return Tok.ident;
    }
}

/**
 * Tokenise `source`.
 *
 * Params:
 *   source = the program text
 *   names  = interner that receives every identifier
 * Returns: the tokens, terminated by a `Tok.eof` token.
 * Throws: `SyntaxError` on a character that starts no token.
 */
Token[] tokenize(string source, Interner names)
{
    import std.array : appender;

    auto toks = appender!(Token[]);
    toks.reserve(source.length / 3 + 2);
    immutable n = source.length;
    size_t i = 0;

    while (i < n)
    {
        immutable char c = source[i];
        immutable uint pos = cast(uint) i;
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            ++i;
        }
        else if (c >= '0' && c <= '9')
        {
            while (i < n && source[i] >= '0' && source[i] <= '9')
                ++i;
            toks.put(Token(Tok.integer, 0, pos));
        }
        else if (c >= 'a' && c <= 'z')
        {
            immutable start = i++;
            while (i < n)
            {
                immutable d = source[i];
                if ((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z')
                        || (d >= '0' && d <= '9') || d == '_')
                    ++i;
                else
                    break;
            }
            auto text = source[start .. i];
            immutable kind = keywordKind(text);
            toks.put(Token(kind, kind == Tok.ident ? names.intern(text) : 0, pos));
        }
        else
        {
            immutable char d = i + 1 < n ? source[i + 1] : '\0';
            Tok kind;
            size_t len = 1;
            switch (c)
            {
            case ';': if (d == ';') { kind = Tok.semiSemi; len = 2; } else kind = Tok.semi; break;
            case '-': if (d == '>') { kind = Tok.arrow; len = 2; } else kind = Tok.minus; break;
            case ':':
                if (d != ':')
                    throw new SyntaxError("unexpected character ':'", i);
                kind = Tok.colonColon; len = 2; break;
            case '<': if (d == '=') { kind = Tok.lessEq; len = 2; } else kind = Tok.less; break;
            case '>': if (d == '=') { kind = Tok.greaterEq; len = 2; } else kind = Tok.greater; break;
            case '&':
                if (d != '&')
                    throw new SyntaxError("unexpected character '&'", i);
                kind = Tok.andAnd; len = 2; break;
            case '|':
                if (d != '|')
                    throw new SyntaxError("unexpected character '|'", i);
                kind = Tok.orOr; len = 2; break;
            case '(': kind = Tok.lparen; break;
            case ')': kind = Tok.rparen; break;
            case '[': kind = Tok.lbracket; break;
            case ']': kind = Tok.rbracket; break;
            case ',': kind = Tok.comma; break;
            case '+': kind = Tok.plus; break;
            case '*': kind = Tok.star; break;
            case '/': kind = Tok.slash; break;
            case '=': kind = Tok.eq; break;
            default:
                throw new SyntaxError("unexpected character", i);
            }
            i += len;
            toks.put(Token(kind, 0, pos));
        }
    }
    toks.put(Token(Tok.eof, 0, cast(uint) n));
    return toks.data;
}
