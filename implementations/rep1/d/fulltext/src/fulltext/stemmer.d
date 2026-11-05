/**
 * The Porter stemming algorithm (1980), following Martin Porter's reference
 * implementation `porter.c` (including its `BLI -> BLE` and `LOGI -> LOG`
 * departures from the published paper).
 *
 * Words are expected to consist of ASCII lower-case letters only; the caller
 * decides which tokens are eligible for stemming (see `fulltext.analysis`).
 */
module fulltext.stemmer;

/**
 * Stems `word` in place and returns the length of the stem, which occupies
 * `word[0 .. result]`. A stem is never longer than the word it came from.
 */
size_t stemInPlace(char[] word) pure nothrow @nogc @safe
{
    if (word.length <= 2)
        return word.length;
    auto s = Stemmer(word, word.length);
    s.step1a();
    s.step1b();
    s.step1c();
    s.step2();
    s.step3();
    s.step4();
    s.step5();
    return s.n;
}

/// Convenience wrapper around $(LREF stemInPlace) that returns a new string.
string stem(const(char)[] word) pure nothrow @safe
{
    auto buf = word.dup;
    immutable n = stemInPlace(buf);
    return (() @trusted => cast(string) buf[0 .. n].idup)();
}

///
@safe pure nothrow unittest
{
    assert(stem("running") == "run");
    assert(stem("caresses") == "caress");
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

// Step 4 suffixes in selection order; "ion" needs an extra condition.
private immutable string[] step4Suffixes = [
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
    "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
];

private struct Stemmer
{
    char[] b; // the word buffer
    size_t n; // current length of the word

    bool cons(size_t i) const pure nothrow @nogc @safe
    {
        switch (b[i])
        {
        case 'a', 'e', 'i', 'o', 'u':
            return false;
        case 'y':
            return i == 0 || !cons(i - 1);
        default:
            return true;
        }
    }

    /// Measure m of the prefix `b[0 .. j]`: the number of VC sequences.
    size_t measure(size_t j) const pure nothrow @nogc @safe
    {
        size_t i = 0, m = 0;
        while (true)
        {
            if (i >= j)
                return m;
            if (!cons(i))
                break;
            ++i;
        }
        ++i;
        while (true)
        {
            while (true)
            {
                if (i >= j)
                    return m;
                if (cons(i))
                    break;
                ++i;
            }
            ++i;
            ++m;
            while (true)
            {
                if (i >= j)
                    return m;
                if (!cons(i))
                    break;
                ++i;
            }
            ++i;
        }
    }

    /// `*v*`: does the prefix `b[0 .. j]` contain a vowel?
    bool hasVowel(size_t j) const pure nothrow @nogc @safe
    {
        foreach (i; 0 .. j)
            if (!cons(i))
                return true;
        return false;
    }

    /// `*d`: does the prefix `b[0 .. j]` end in a doubled consonant?
    bool doubleC(size_t j) const pure nothrow @nogc @safe
    {
        return j >= 2 && b[j - 1] == b[j - 2] && cons(j - 1);
    }

    /// `*o`: does the prefix `b[0 .. j]` end consonant-vowel-consonant (not w, x, y)?
    bool cvc(size_t j) const pure nothrow @nogc @safe
    {
        if (j < 3 || !cons(j - 1) || cons(j - 2) || !cons(j - 3))
            return false;
        immutable c = b[j - 1];
        return c != 'w' && c != 'x' && c != 'y';
    }

    bool ends(string suffix) const pure nothrow @nogc @safe
    {
        return n >= suffix.length && b[n - suffix.length .. n] == suffix;
    }

    void append(char c) pure nothrow @nogc @safe
    {
        b[n++] = c;
    }

    /// Replaces the suffix of length `cut` by `replacement`.
    void replaceSuffix(size_t cut, string replacement) pure nothrow @nogc @safe
    {
        n -= cut;
        foreach (c; replacement)
            append(c);
    }

    void step1a() pure nothrow @nogc @safe
    {
        if (b[n - 1] != 's')
            return;
        if (ends("sses"))
            n -= 2;
        else if (ends("ies"))
            n -= 2;
        else if (ends("ss"))
        {
        }
        else
            n -= 1;
    }

    void step1b() pure nothrow @nogc @safe
    {
        if (ends("eed"))
        {
            if (measure(n - 3) > 0)
                n -= 1;
            return;
        }
        bool removed = false;
        if (ends("ed"))
        {
            if (hasVowel(n - 2))
            {
                n -= 2;
                removed = true;
            }
        }
        else if (ends("ing"))
        {
            if (hasVowel(n - 3))
            {
                n -= 3;
                removed = true;
            }
        }
        if (!removed)
            return;
        if (ends("at") || ends("bl") || ends("iz"))
            append('e');
        else if (doubleC(n))
        {
            immutable c = b[n - 1];
            if (c != 'l' && c != 's' && c != 'z')
                n -= 1;
        }
        else if (measure(n) == 1 && cvc(n))
            append('e');
    }

    void step1c() pure nothrow @nogc @safe
    {
        if (b[n - 1] == 'y' && hasVowel(n - 1))
            b[n - 1] = 'i';
    }

    void applyRules(const Rule[] rules) pure nothrow @nogc @safe
    {
        foreach (ref r; rules)
        {
            if (ends(r.suffix))
            {
                if (measure(n - r.suffix.length) > 0)
                    replaceSuffix(r.suffix.length, r.replacement);
                return;
            }
        }
    }

    void step2() pure nothrow @nogc @safe
    {
        applyRules(step2Rules);
    }

    void step3() pure nothrow @nogc @safe
    {
        applyRules(step3Rules);
    }

    void step4() pure nothrow @nogc @safe
    {
        foreach (suffix; step4Suffixes)
        {
            if (!ends(suffix))
                continue;
            immutable stem = n - suffix.length;
            if (measure(stem) > 1)
            {
                if (suffix == "ion" && !(stem > 0 && (b[stem - 1] == 's' || b[stem - 1] == 't')))
                    return;
                n = stem;
            }
            return;
        }
    }

    void step5() pure nothrow @nogc @safe
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
