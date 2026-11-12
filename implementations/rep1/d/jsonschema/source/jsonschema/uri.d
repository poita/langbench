/**
 * RFC 3986 URI references (splitting, strict reference resolution,
 * `remove_dot_segments`) and RFC 6901 JSON Pointer helpers.
 */
module jsonschema.uri;

import jsonschema.json;

/// A URI reference split into its five components.
struct UriRef
{
    string scheme; /// valid when `hasScheme`
    string authority; /// valid when `hasAuthority`
    string path; /// always defined (possibly empty)
    string query; /// valid when `hasQuery`
    string fragment; /// valid when `hasFragment`
    bool hasScheme, hasAuthority, hasQuery, hasFragment;

    /// Recomposes the reference into text (RFC 3986 section 5.3).
    string toString() const
    {
        string r;
        if (hasScheme)
            r ~= scheme ~ ":";
        if (hasAuthority)
            r ~= "//" ~ authority;
        r ~= path;
        if (hasQuery)
            r ~= "?" ~ query;
        if (hasFragment)
            r ~= "#" ~ fragment;
        return r;
    }

    /// The reference with its fragment removed.
    UriRef withoutFragment() const
    {
        UriRef u = this;
        u.hasFragment = false;
        u.fragment = null;
        return u;
    }
}

/// Splits a URI reference (RFC 3986 appendix B).
UriRef parseUri(string s)
{
    UriRef u;
    size_t i = 0;
    // scheme: [^:/?#]+ ':'
    size_t j = 0;
    while (j < s.length && s[j] != ':' && s[j] != '/' && s[j] != '?' && s[j] != '#')
        j++;
    if (j > 0 && j < s.length && s[j] == ':')
    {
        u.hasScheme = true;
        u.scheme = s[0 .. j];
        i = j + 1;
    }
    if (i + 1 < s.length && s[i] == '/' && s[i + 1] == '/')
    {
        i += 2;
        size_t k = i;
        while (k < s.length && s[k] != '/' && s[k] != '?' && s[k] != '#')
            k++;
        u.hasAuthority = true;
        u.authority = s[i .. k];
        i = k;
    }
    size_t k = i;
    while (k < s.length && s[k] != '?' && s[k] != '#')
        k++;
    u.path = s[i .. k];
    i = k;
    if (i < s.length && s[i] == '?')
    {
        i++;
        k = i;
        while (k < s.length && s[k] != '#')
            k++;
        u.hasQuery = true;
        u.query = s[i .. k];
        i = k;
    }
    if (i < s.length && s[i] == '#')
    {
        u.hasFragment = true;
        u.fragment = s[i + 1 .. $];
    }
    return u;
}

/// RFC 3986 section 5.2.4.
string removeDotSegments(string path)
{
    string output;
    string input = path;
    import std.algorithm.searching : startsWith;

    while (input.length)
    {
        if (input.startsWith("../"))
            input = input[3 .. $];
        else if (input.startsWith("./"))
            input = input[2 .. $];
        else if (input.startsWith("/./"))
            input = input[2 .. $];
        else if (input == "/.")
            input = "/";
        else if (input.startsWith("/../") || input == "/..")
        {
            input = input.length == 3 ? "/" : input[3 .. $];
            auto idx = lastSlash(output);
            output = idx < 0 ? "" : output[0 .. idx];
        }
        else if (input == "." || input == "..")
            input = "";
        else
        {
            size_t end = 0;
            if (input[0] == '/')
                end = 1;
            while (end < input.length && input[end] != '/')
                end++;
            output ~= input[0 .. end];
            input = input[end .. $];
        }
    }
    return output;
}

private ptrdiff_t lastSlash(string s)
{
    for (ptrdiff_t i = cast(ptrdiff_t) s.length - 1; i >= 0; i--)
        if (s[i] == '/')
            return i;
    return -1;
}

/// RFC 3986 section 5.2.2 strict resolution of `ref_` against `base`.
UriRef resolve(const UriRef base, const UriRef ref_)
{
    UriRef t;
    if (ref_.hasScheme)
    {
        t = ref_;
        t.path = removeDotSegments(ref_.path);
    }
    else
    {
        if (ref_.hasAuthority)
        {
            t.hasAuthority = true;
            t.authority = ref_.authority;
            t.path = removeDotSegments(ref_.path);
            t.hasQuery = ref_.hasQuery;
            t.query = ref_.query;
        }
        else
        {
            if (ref_.path.length == 0)
            {
                t.path = base.path;
                if (ref_.hasQuery)
                {
                    t.hasQuery = true;
                    t.query = ref_.query;
                }
                else
                {
                    t.hasQuery = base.hasQuery;
                    t.query = base.query;
                }
            }
            else
            {
                if (ref_.path[0] == '/')
                    t.path = removeDotSegments(ref_.path);
                else
                    t.path = removeDotSegments(mergePaths(base, ref_.path));
                t.hasQuery = ref_.hasQuery;
                t.query = ref_.query;
            }
            t.hasAuthority = base.hasAuthority;
            t.authority = base.authority;
        }
        t.hasScheme = base.hasScheme;
        t.scheme = base.scheme;
    }
    t.hasFragment = ref_.hasFragment;
    t.fragment = ref_.fragment;
    return t;
}

private string mergePaths(const UriRef base, string refPath)
{
    if (base.hasAuthority && base.path.length == 0)
        return "/" ~ refPath;
    auto idx = lastSlash(base.path);
    if (idx < 0)
        return refPath;
    return base.path[0 .. idx + 1] ~ refPath;
}

/// Resolves the reference text `ref_` against the base text `base`.
UriRef resolveString(string base, string ref_)
{
    return resolve(parseUri(base), parseUri(ref_));
}

/// Percent-decodes `s` (invalid escapes are left as they are).
string percentDecode(string s)
{
    bool any = false;
    foreach (c; s)
        if (c == '%')
        {
            any = true;
            break;
        }
    if (!any)
        return s;
    char[] r;
    for (size_t i = 0; i < s.length; i++)
    {
        if (s[i] == '%' && i + 2 < s.length && hexv(s[i + 1]) >= 0 && hexv(s[i + 2]) >= 0)
        {
            r ~= cast(char)(hexv(s[i + 1]) * 16 + hexv(s[i + 2]));
            i += 2;
        }
        else
            r ~= s[i];
    }
    return cast(string) r;
}

private int hexv(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// Splits an RFC 6901 pointer (already percent-decoded, starting with `/`)
/// into unescaped reference tokens.
string[] pointerTokens(string pointer)
{
    string[] tokens;
    if (pointer.length == 0)
        return tokens;
    size_t i = 1;
    size_t start = 1;
    for (; i <= pointer.length; i++)
    {
        if (i == pointer.length || pointer[i] == '/')
        {
            tokens ~= unescapeToken(pointer[start .. i]);
            start = i + 1;
        }
    }
    return tokens;
}

private string unescapeToken(string t)
{
    bool any = false;
    foreach (c; t)
        if (c == '~')
        {
            any = true;
            break;
        }
    if (!any)
        return t;
    char[] r;
    for (size_t i = 0; i < t.length; i++)
    {
        if (t[i] == '~' && i + 1 < t.length && t[i + 1] == '0')
        {
            r ~= '~';
            i++;
        }
        else if (t[i] == '~' && i + 1 < t.length && t[i + 1] == '1')
        {
            r ~= '/';
            i++;
        }
        else
            r ~= t[i];
    }
    return cast(string) r;
}

/// Evaluates a JSON Pointer against `root`; returns `null` when it does not
/// lead anywhere.
JsonValue evalPointer(JsonValue root, string pointer)
{
    auto cur = root;
    foreach (tok; pointerTokens(pointer))
    {
        if (cur is null)
            return null;
        if (cur.isObject)
            cur = cur.get(tok);
        else if (cur.isArray)
        {
            size_t idx = 0;
            if (tok.length == 0 || (tok.length > 1 && tok[0] == '0'))
                return null;
            foreach (c; tok)
            {
                if (c < '0' || c > '9')
                    return null;
                idx = idx * 10 + (c - '0');
            }
            cur = idx < cur.items.length ? cur.items[idx] : null;
        }
        else
            return null;
    }
    return cur;
}

unittest
{
    // RFC 3986 section 5.4 examples.
    enum base = "http://a/b/c/d;p?q";
    void check(string r, string want)
    {
        auto got = resolveString(base, r).toString();
        assert(got == want, r ~ " -> " ~ got ~ " (want " ~ want ~ ")");
    }

    check("g:h", "g:h");
    check("g", "http://a/b/c/g");
    check("./g", "http://a/b/c/g");
    check("g/", "http://a/b/c/g/");
    check("/g", "http://a/g");
    check("//g", "http://g");
    check("?y", "http://a/b/c/d;p?y");
    check("g?y", "http://a/b/c/g?y");
    check("#s", "http://a/b/c/d;p?q#s");
    check("g#s", "http://a/b/c/g#s");
    check("", "http://a/b/c/d;p?q");
    check(".", "http://a/b/c/");
    check("..", "http://a/b/");
    check("../g", "http://a/b/g");
    check("../..", "http://a/");
    check("../../../g", "http://a/g");
    check("/./g", "http://a/g");
    check("g/../h", "http://a/b/c/h");
    check("g;x=1/../y", "http://a/b/c/y");
}

unittest
{
    assert(resolveString("", "#foo").toString() == "#foo");
    assert(resolveString("", "foo.json").toString() == "foo.json");
    assert(resolveString("urn:uuid:deadbeef", "#/x").toString() == "urn:uuid:deadbeef#/x");
    assert(resolveString("http://x", "y").toString() == "http://x/y");
    assert(percentDecode("a%25b%C3%A9") == "a%bé");
    assert(pointerTokens("/a~1b/c~0d/") == ["a/b", "c~d", ""]);
}

unittest
{
    auto doc = parseJson(`{"a":{"b":[10,20]},"c/d":1}`);
    assert(evalPointer(doc, "/a/b/1").number.toCount() == 20);
    assert(evalPointer(doc, "/c~1d") !is null);
    assert(evalPointer(doc, "/a/x") is null);
    assert(evalPointer(doc, "") is doc);
}
