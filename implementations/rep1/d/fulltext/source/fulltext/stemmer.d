/**
 * The Porter stemmer (Porter, 1980) in the form of Martin Porter's reference
 * implementation `porter.c`, including its two departures from the published
 * paper (`BLI -> BLE` and the extra `LOGI -> LOG` rule in step 2).
 *
 * Only words made of the ASCII letters `a`–`z` may be stemmed.
 */
module fulltext.stemmer;

@safe:

/**
 * Returns the Porter stem of `word`, which must consist only of the ASCII
 * lower-case letters `a`–`z`. Words of one or two letters are returned
 * unchanged.
 */
string stem(const(char)[] word) pure nothrow
{
    if (word.length <= 2)
        return word.idup;
    auto s = Stemmer(word.dup);
    s.run();
    return s.b[0 .. s.n].idup;
}

///
unittest
{
    assert(stem("running") == "run");
    assert(stem("connections") == "connect");
    assert(stem("relational") == "relat");
    assert(stem("feed") == "feed");
}

private struct Rule
{
    string suffix;
    string replacement;
}

private immutable Rule[] step2Rules = [
    Rule("ational", "ate"), Rule("tional", "tion"), Rule("enci", "ence"),
    Rule("anci", "ance"), Rule("izer", "ize"), Rule("bli", "ble"),
    Rule("alli", "al"), Rule("entli", "ent"), Rule("eli", "e"),
    Rule("ousli", "ous"), Rule("ization", "ize"), Rule("ation", "ate"),
    Rule("ator", "ate"), Rule("alism", "al"), Rule("iveness", "ive"),
    Rule("fulness", "ful"), Rule("ousness", "ous"), Rule("aliti", "al"),
    Rule("iviti", "ive"), Rule("biliti", "ble"), Rule("logi", "log"),
];

private immutable Rule[] step3Rules = [
    Rule("icate", "ic"), Rule("ative", ""), Rule("alize", "al"),
    Rule("iciti", "ic"), Rule("ical", "ic"), Rule("ful", ""), Rule("ness", ""),
];

private immutable string[] step4Suffixes = [
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
    "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
];

/// Working state: the word lives in `b[0 .. n]`.
private struct Stemmer
{
    char[] b;
    size_t n;

    this(char[] word) pure nothrow
    {
        b = word;
        n = word.length;
    }

    /// Is `b[i]` a consonant?
    bool cons(size_t i) const pure nothrow @nogc
    {
        switch (b[i])
        {
            case 'a', 'e', 'i', 'o', 'u':
                return false;
            case 'y':
                return i == 0 ? true : !cons(i - 1);
            default:
                return true;
        }
    }

    /// Measure of the prefix `b[0 .. len]`.
    int measure(size_t len) const pure nothrow @nogc
    {
        int m = 0;
        size_t i = 0;
        // skip leading consonants
        while (i < len && cons(i))
            i++;
        while (true)
        {
            // vowel run
            while (i < len && !cons(i))
                i++;
            if (i >= len)
                return m;
            // consonant run: completes one VC
            while (i < len && cons(i))
                i++;
            m++;
        }
    }

    /// Does the prefix `b[0 .. len]` contain a vowel?
    bool hasVowel(size_t len) const pure nothrow @nogc
    {
        foreach (i; 0 .. len)
            if (!cons(i))
                return true;
        return false;
    }

    /// Does the prefix of length `len` end in a double consonant?
    bool doubleC(size_t len) const pure nothrow @nogc
    {
        return len >= 2 && b[len - 1] == b[len - 2] && cons(len - 1);
    }

    /// Does the prefix of length `len` end consonant-vowel-consonant with the
    /// last consonant not w, x or y?
    bool cvc(size_t len) const pure nothrow @nogc
    {
        if (len < 3 || !cons(len - 1) || cons(len - 2) || !cons(len - 3))
            return false;
        immutable ch = b[len - 1];
        return ch != 'w' && ch != 'x' && ch != 'y';
    }

    bool endsWith(string suffix) const pure nothrow @nogc
    {
        return n >= suffix.length && b[n - suffix.length .. n] == suffix;
    }

    /// Replace the last `cut` letters by `repl`.
    void replaceTail(size_t cut, string repl) pure nothrow
    {
        immutable stemLen = n - cut;
        immutable newLen = stemLen + repl.length;
        if (b.length < newLen)
            b.length = newLen;
        b[stemLen .. newLen] = repl[];
        n = newLen;
    }

    void run() pure nothrow
    {
        step1a();
        step1b();
        step1c();
        step2or3(step2Rules);
        step2or3(step3Rules);
        step4();
        step5();
    }

    void step1a() pure nothrow
    {
        if (b[n - 1] != 's')
            return;
        if (endsWith("sses"))
            n -= 2;
        else if (endsWith("ies"))
            replaceTail(3, "i");
        else if (endsWith("ss"))
        {
        }
        else
            n -= 1;
    }

    void step1b() pure nothrow
    {
        bool removed = false;
        if (endsWith("eed"))
        {
            if (measure(n - 3) > 0)
                n -= 1;
            return;
        }
        else if (endsWith("ed"))
        {
            if (hasVowel(n - 2))
            {
                n -= 2;
                removed = true;
            }
        }
        else if (endsWith("ing"))
        {
            if (hasVowel(n - 3))
            {
                n -= 3;
                removed = true;
            }
        }
        if (!removed)
            return;
        if (endsWith("at"))
            replaceTail(2, "ate");
        else if (endsWith("bl"))
            replaceTail(2, "ble");
        else if (endsWith("iz"))
            replaceTail(2, "ize");
        else if (doubleC(n))
        {
            immutable ch = b[n - 1];
            if (ch != 'l' && ch != 's' && ch != 'z')
                n -= 1;
        }
        else if (measure(n) == 1 && cvc(n))
            replaceTail(0, "e");
    }

    void step1c() pure nothrow
    {
        if (b[n - 1] == 'y' && hasVowel(n - 1))
            b[n - 1] = 'i';
    }

    /// Steps 2 and 3: first matching suffix is selected; it fires when the
    /// stem has measure > 0.
    void step2or3(immutable(Rule)[] rules) pure nothrow
    {
        foreach (ref r; rules)
        {
            if (endsWith(r.suffix))
            {
                if (measure(n - r.suffix.length) > 0)
                    replaceTail(r.suffix.length, r.replacement);
                return;
            }
        }
    }

    void step4() pure nothrow
    {
        foreach (suffix; step4Suffixes)
        {
            if (!endsWith(suffix))
                continue;
            immutable stemLen = n - suffix.length;
            if (suffix == "ion")
            {
                if (stemLen == 0 || (b[stemLen - 1] != 's' && b[stemLen - 1] != 't'))
                    return;
            }
            if (measure(stemLen) > 1)
                n = stemLen;
            return;
        }
    }

    void step5() pure nothrow
    {
        if (b[n - 1] == 'e')
        {
            immutable m = measure(n - 1);
            if (m > 1 || (m == 1 && !cvc(n - 1)))
                n -= 1;
        }
        if (b[n - 1] == 'l' && doubleC(n) && measure(n) > 1)
            n -= 1;
    }
}

unittest
{
    // Examples from the specification's rule tables.
    immutable string[2][] cases = [
        ["caresses", "caress"], ["ponies", "poni"], ["ties", "ti"],
        ["caress", "caress"], ["cats", "cat"], ["feed", "feed"],
        ["agreed", "agre"], ["plastered", "plaster"], ["bled", "bled"],
        ["motoring", "motor"], ["sing", "sing"], ["conflated", "conflat"],
        ["troubled", "troubl"], ["sized", "size"], ["hopping", "hop"],
        ["tanned", "tan"], ["falling", "fall"], ["fizzed", "fizz"],
        ["filing", "file"], ["failing", "fail"], ["happy", "happi"],
        ["sky", "sky"], ["relational", "relat"], ["conditional", "condit"],
        ["digitizer", "digit"], ["vietnamization", "vietnam"],
        ["operator", "oper"], ["triplicate", "triplic"],
        ["formative", "form"], ["formalize", "formal"],
        ["electrical", "electr"], ["hopeful", "hope"], ["goodness", "good"],
        ["revival", "reviv"], ["allowance", "allow"], ["inference", "infer"],
        ["adoption", "adopt"], ["probate", "probat"], ["rate", "rate"],
        ["cease", "ceas"], ["controll", "control"], ["roll", "roll"],
        ["running", "run"], ["runs", "run"], ["runner", "runner"],
        ["connection", "connect"], ["connections", "connect"],
        ["connecting", "connect"], ["dogs", "dog"], ["happiness", "happi"],
        ["happier", "happier"], ["relativity", "rel"],
        ["sensibility", "sensibl"], ["national", "nation"],
        ["controlled", "control"], ["abandoned", "abandon"],
        ["need", "need"], ["bleed", "bleed"], ["deed", "deed"],
        ["a", "a"], ["is", "is"], ["by", "by"], ["ion", "ion"],
        ["apologi", "apolog"], ["conformabli", "conform"],
    ];
    foreach (c; cases)
        assert(stem(c[0]) == c[1], c[0] ~ " -> " ~ stem(c[0]) ~ ", expected " ~ c[1]);
}

/// Porter's own vocabulary (a sample of voc.txt / output.txt, one
/// "word stem" pair per line).
unittest
{
    import std.algorithm : splitter;
    import std.string : lineSplitter;

    enum data = import("porter_sample.txt");
    size_t count;
    foreach (line; data.lineSplitter)
    {
        if (line.length == 0)
            continue;
        auto parts = line.splitter(' ');
        immutable word = parts.front;
        parts.popFront();
        immutable expected = parts.front;
        assert(stem(word) == expected, word ~ " -> " ~ stem(word) ~ ", expected " ~ expected);
        count++;
    }
    assert(count > 1000);
}
