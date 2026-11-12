/**
 * Text analysis: tokenising, case folding and stop words.
 *
 * Documents and queries go through the same pipeline: $(LREF tokenize) cuts a
 * text into tokens, $(LREF foldToken) normalises each token, and
 * `fulltext.stemmer.stem` (applied by `fulltext.index`) reduces ASCII words to
 * their stems.
 *
 * $(B Token characters) are ASCII digits and letters, the Latin letters
 * U+00C0–U+024F (without × and ÷), Greek and Coptic (U+0370–U+03FF) and
 * Cyrillic (U+0400–U+04FF). Everything else separates tokens. A token is one
 * or more token characters, optionally continued by single apostrophes
 * (U+0027 or U+2019) that sit between two token characters.
 *
 * All offsets reported by this module are UTF-8 code-unit (byte) offsets into
 * the analysed string; they always fall on code point boundaries.
 */
module fulltext.analysis;

import std.utf : decode;

import fulltext.stemmer : stem;

@safe:

/// True if `c` is a token character.
bool isTokenChar(dchar c) pure nothrow @nogc
{
    if (c < 0x80)
        return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    return (c >= 0x00C0 && c <= 0x00D6) || (c >= 0x00D8 && c <= 0x00F6)
        || (c >= 0x00F8 && c <= 0x024F) || (c >= 0x0370 && c <= 0x04FF);
}

/// True for U+0027 and U+2019.
bool isApostrophe(dchar c) pure nothrow @nogc
{
    return c == '\'' || c == '’';
}

/// True for the seven whitespace code points the specification recognises:
/// U+0009–U+000D, U+0020 and U+00A0.
bool isSpace(dchar c) pure nothrow @nogc
{
    return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0xA0;
}

/// A token found in a text.
struct Token
{
    /// Byte offset of the first code unit of the token.
    size_t begin;
    /// Byte offset one past the last code unit of the token.
    size_t end;
    /// 0-based index of the token in the token sequence of the text.
    uint position;
}

/**
 * Lazily splits a text into $(LREF Token)s. This is an input range; use
 * $(LREF tokenize) to construct it.
 */
struct Tokenizer
{
    private string text_;
    private size_t pos_;
    private uint nextPosition_;
    private Token front_;
    private bool empty_;

    this(string text) pure
    {
        text_ = text;
        advance();
    }

    /// True when no tokens are left.
    @property bool empty() const pure nothrow @nogc { return empty_; }

    /// The current token.
    @property Token front() const pure nothrow @nogc { return front_; }

    /// Moves to the next token.
    void popFront() pure
    {
        advance();
    }

    /// The analysed text.
    @property string text() const pure nothrow @nogc { return text_; }

    private void advance() pure
    {
        size_t i = pos_;
        immutable n = text_.length;
        while (i < n)
        {
            size_t j = i;
            dchar c = decode(text_, j);
            if (!isTokenChar(c))
            {
                i = j;
                continue;
            }
            immutable start = i;
            i = j;
            while (i < n)
            {
                j = i;
                c = decode(text_, j);
                if (isTokenChar(c))
                {
                    i = j;
                    continue;
                }
                if (isApostrophe(c) && j < n)
                {
                    size_t k = j;
                    if (isTokenChar(decode(text_, k)))
                    {
                        i = k;
                        continue;
                    }
                }
                break;
            }
            front_ = Token(start, i, nextPosition_++);
            pos_ = i;
            return;
        }
        pos_ = n;
        empty_ = true;
    }
}

/// Returns a lazy range over the tokens of `text`.
Tokenizer tokenize(string text) pure
{
    return Tokenizer(text);
}

///
unittest
{
    import std.algorithm : map;
    import std.array : array;

    string text = "Don't stop, well-known";
    auto words = tokenize(text).map!(t => text[t.begin .. t.end]).array;
    assert(words == ["Don't", "stop", "well", "known"]);
}

/**
 * Folds the token text `raw`: deletes apostrophes and maps `A`–`Z` to `a`–`z`.
 * No other case mapping is applied.
 *
 * The result is written into `buf` (which is reused and grown as needed) and
 * returned as a slice of it, so it is only valid until the next call that
 * uses the same buffer.
 */
const(char)[] foldInto(const(char)[] raw, ref char[] buf) pure nothrow
{
    if (buf.length < raw.length)
        buf.length = raw.length;
    size_t n = 0;
    for (size_t i = 0; i < raw.length; i++)
    {
        immutable ch = raw[i];
        if (ch == '\'')
            continue;
        // U+2019 is E2 80 99 in UTF-8.
        if (ch == 0xE2 && i + 2 < raw.length && raw[i + 1] == 0x80 && raw[i + 2] == 0x99)
        {
            i += 2;
            continue;
        }
        buf[n++] = (ch >= 'A' && ch <= 'Z') ? cast(char)(ch + 32) : ch;
    }
    return buf[0 .. n];
}

/// Allocating variant of $(LREF foldInto).
string foldToken(const(char)[] raw) pure nothrow
{
    char[] buf;
    return foldInto(raw, buf).idup;
}

///
unittest
{
    assert(foldToken("Don’t") == "dont");
    assert(foldToken("CAFÉ") == "cafÉ");
    assert(foldToken("rock'n'roll") == "rocknroll");
}

/// True if `word` (a folded token text) is one of the 33 stop words.
bool isStopWord(const(char)[] word) pure nothrow @nogc
{
    switch (word)
    {
        case "a", "an", "and", "are", "as", "at", "be", "but", "by",
             "for", "if", "in", "into", "is", "it", "no", "not", "of",
             "on", "or", "such", "that", "the", "their", "then", "there", "these",
             "they", "this", "to", "was", "will", "with":
            return true;
        default:
            return false;
    }
}

/// True if every code unit of `word` is an ASCII letter `a`–`z`.
bool isLowerAscii(const(char)[] word) pure nothrow @nogc
{
    if (word.length == 0)
        return false;
    foreach (ch; word)
        if (ch < 'a' || ch > 'z')
            return false;
    return true;
}

unittest
{
    import std.algorithm : equal, map;

    static string[] toks(string s)
    {
        string[] r;
        foreach (t; tokenize(s))
            r ~= s[t.begin .. t.end];
        return r;
    }

    assert(toks("The cat sat.") == ["The", "cat", "sat"]);
    assert(toks("'quoted'") == ["quoted"]);
    assert(toks("rock'n'roll") == ["rock'n'roll"]);
    assert(toks("a''b") == ["a", "b"]);
    assert(toks("Version 1.2.3") == ["Version", "1", "2", "3"]);
    assert(toks("X1 XY2Z") == ["X1", "XY2Z"]);
    assert(toks("Don’t") == ["Don’t"]);
    assert(toks("a’") == ["a"]);
    assert(toks("3 × 4 ÷ 2") == ["3", "4", "2"]);
    assert(toks("Ωmega привет 日本") == ["Ωmega", "привет"]);
    assert(toks("").length == 0);
    assert(toks("   ...  ").length == 0);

    // positions and offsets
    auto r = tokenize("ab cd");
    assert(r.front == Token(0, 2, 0));
    r.popFront();
    assert(r.front == Token(3, 5, 1));
    r.popFront();
    assert(r.empty);
}

unittest
{
    assert(isStopWord("the") && isStopWord("with") && isStopWord("a"));
    assert(!isStopWord("cat") && !isStopWord("The") && !isStopWord(""));
    assert(isLowerAscii("abc") && !isLowerAscii("ab1") && !isLowerAscii("café") && !isLowerAscii(""));
}

/**
 * The index term for a folded token text: its Porter stem when the text is
 * made only of the letters `a`–`z`, the text itself otherwise.
 */
string termOf(const(char)[] folded) pure nothrow
{
    return isLowerAscii(folded) ? stem(folded) : folded.idup;
}

unittest
{
    assert(termOf("running") == "run");
    assert(termOf("x2") == "x2");
    assert(termOf("café") == "café");
}

/// One analysed token of a text.
struct AnalyzedToken
{
    /// Location of the token in the source text.
    Token span;
    /// The folded token text (apostrophes removed, ASCII lower-cased).
    string folded;
    /// The index term (stemmed when applicable).
    string term;
}

/// Runs the whole pipeline (tokenise, fold, stem) over `text`.
AnalyzedToken[] analyze(string text) pure
{
    AnalyzedToken[] result;
    char[] buf;
    foreach (tok; tokenize(text))
    {
        auto folded = foldInto(text[tok.begin .. tok.end], buf);
        result ~= AnalyzedToken(tok, folded.idup, termOf(folded));
    }
    return result;
}

unittest
{
    auto toks = analyze("The Running dogs' 2nd");
    assert(toks.length == 4);
    assert(toks[0].folded == "the" && toks[0].term == "the");
    assert(toks[1].term == "run");
    assert(toks[2].folded == "dogs" && toks[2].term == "dog");
    assert(toks[3].term == "2nd");
}
