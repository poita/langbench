/**
 * Text analysis: tokenising, case folding, stop words and term extraction.
 *
 * Documents and queries go through the same pipeline. The tokeniser works
 * directly on UTF-8 bytes and reports byte offsets, so callers can slice the
 * original text without ever decoding it into code points.
 */
module fulltext.analysis;

import fulltext.stemmer : stemInPlace;

/// Half-open byte range `[start, end)` of a token in the source text.
struct Span
{
    uint start;
    uint end;
}

/// Is `c` one of the token characters of the specification?
bool isTokenChar(dchar c) pure nothrow @nogc @safe
{
    if (c < 0x80)
        return asciiTokenChar[c];
    return (c >= 0xC0 && c <= 0xD6) || (c >= 0xD8 && c <= 0xF6)
        || (c >= 0xF8 && c <= 0x24F) || (c >= 0x370 && c <= 0x4FF);
}

/// Is `c` an apostrophe (U+0027 or U+2019)?
bool isApostrophe(dchar c) pure nothrow @nogc @safe
{
    return c == '\'' || c == 0x2019;
}

private immutable bool[128] asciiTokenChar = () {
    bool[128] t;
    foreach (c; '0' .. '9' + 1)
        t[c] = true;
    foreach (c; 'A' .. 'Z' + 1)
        t[c] = true;
    foreach (c; 'a' .. 'z' + 1)
        t[c] = true;
    return t;
}();

/// Decodes the code point at `s[i]`. Malformed input decodes as a one-byte
/// U+FFFD, which is a separator.
private dchar decodeAt(const(ubyte)[] s, size_t i, out size_t len) pure nothrow @nogc @safe
{
    immutable b0 = s[i];
    if (b0 < 0x80)
    {
        len = 1;
        return b0;
    }
    size_t need = 0;
    dchar cp = 0;
    if (b0 >= 0xC2 && b0 <= 0xDF)
    {
        need = 1;
        cp = b0 & 0x1F;
    }
    else if (b0 >= 0xE0 && b0 <= 0xEF)
    {
        need = 2;
        cp = b0 & 0x0F;
    }
    else if (b0 >= 0xF0 && b0 <= 0xF4)
    {
        need = 3;
        cp = b0 & 0x07;
    }
    else
    {
        len = 1;
        return 0xFFFD;
    }
    if (i + need >= s.length)
    {
        len = 1;
        return 0xFFFD;
    }
    foreach (k; 1 .. need + 1)
    {
        immutable bk = s[i + k];
        if ((bk & 0xC0) != 0x80)
        {
            len = 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | (bk & 0x3F);
    }
    len = need + 1;
    return cp;
}

/**
 * Input range over the tokens of a UTF-8 text, yielding their byte `Span`s.
 *
 * A token is a maximal run of token characters, optionally continued by
 * single apostrophes that sit between two token characters.
 */
struct Tokenizer
{
    private const(ubyte)[] text;
    private size_t pos;
    private Span current;
    private bool done;

    /// Starts tokenising `text`.
    this(const(ubyte)[] text) pure nothrow @nogc @safe
    {
        this.text = text;
        popFront();
    }

    /// ditto
    this(const(char)[] text) pure nothrow @nogc @trusted
    {
        this(cast(const(ubyte)[]) text);
    }

    /// True when no tokens remain.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return done;
    }

    /// The current token's span.
    @property Span front() const pure nothrow @nogc @safe
    {
        return current;
    }

    /// Advances to the next token.
    void popFront() pure nothrow @nogc @safe
    {
        size_t len;
        // Find the first token character.
        while (true)
        {
            if (pos >= text.length)
            {
                done = true;
                return;
            }
            immutable c = decodeAt(text, pos, len);
            if (isTokenChar(c))
                break;
            pos += len;
        }
        immutable start = pos;
        pos += len;
        // Extend over token characters and inner apostrophes.
        while (pos < text.length)
        {
            immutable c = decodeAt(text, pos, len);
            if (isTokenChar(c))
            {
                pos += len;
            }
            else if (isApostrophe(c))
            {
                size_t len2;
                if (pos + len >= text.length)
                    break;
                immutable c2 = decodeAt(text, pos + len, len2);
                if (!isTokenChar(c2))
                    break;
                pos += len + len2;
            }
            else
                break;
        }
        current = Span(cast(uint) start, cast(uint) pos);
    }
}

///
@safe pure nothrow unittest
{
    import std.array : array;

    assert(Tokenizer("don't stop").array == [Span(0, 5), Span(6, 10)]);
}

/// The 33 stop words, as token texts.
immutable string[] stopWords = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in",
    "into", "is", "it", "no", "not", "of", "on", "or", "such", "that", "the",
    "their", "then", "there", "these", "they", "this", "to", "was", "will",
    "with",
];

/// Is `tokenText` (already folded) a stop word?
bool isStopWord(const(char)[] tokenText) pure nothrow @nogc @safe
{
    if (tokenText.length > 5 || tokenText.length == 0)
        return false;
    foreach (w; stopWords)
        if (w == tokenText)
            return true;
    return false;
}

/**
 * Reusable analyser that turns raw token bytes into terms without
 * allocating (after its scratch buffer has grown to the longest token).
 */
struct TermAnalyzer
{
    private char[] buf;

    /**
     * Folds `raw` (apostrophes deleted, `A`–`Z` lower-cased). The result
     * lives in the analyser's scratch buffer and is valid until the next call.
     */
    const(char)[] fold(const(ubyte)[] raw) pure nothrow @safe
    {
        if (buf.length < raw.length)
            buf.length = raw.length;
        size_t n = 0;
        size_t i = 0;
        while (i < raw.length)
        {
            immutable c = raw[i];
            if (c == '\'')
            {
                ++i;
            }
            else if (c == 0xE2 && i + 2 < raw.length && raw[i + 1] == 0x80 && raw[i + 2] == 0x99)
            {
                i += 3;
            }
            else
            {
                buf[n++] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : cast(char) c;
                ++i;
            }
        }
        return buf[0 .. n];
    }

    /**
     * Analyses one raw token: folds it, sets `stop` to whether the folded
     * text is a stop word, and returns its term (the Porter stem when the
     * folded text is purely `a`–`z`, otherwise the folded text). The result
     * lives in the scratch buffer.
     */
    const(char)[] analyze(const(ubyte)[] raw, out bool stop) pure nothrow @safe
    {
        auto folded = fold(raw);
        stop = isStopWord(folded);
        bool alpha = folded.length > 0;
        foreach (c; folded)
            if (c < 'a' || c > 'z')
            {
                alpha = false;
                break;
            }
        if (!alpha)
            return folded;
        immutable n = stemInPlace(buf[0 .. folded.length]);
        return buf[0 .. n];
    }
}

/// Analyses a whole text into its sequence of terms.
string[] analyzeText(const(char)[] text) pure @trusted
{
    string[] terms;
    TermAnalyzer an;
    auto bytes = cast(const(ubyte)[]) text;
    foreach (span; Tokenizer(bytes))
    {
        bool stop;
        terms ~= an.analyze(bytes[span.start .. span.end], stop).idup;
    }
    return terms;
}

///
@safe pure unittest
{
    assert(analyzeText("The Dogs' running") == ["the", "dog", "run"]);
}
