/**
 * RFC 3986 URI references: splitting, strict reference resolution
 * (section 5.2.2), `remove_dot_segments`, recomposition, and percent-decoding.
 */
module jsonschema.uri;

/// The five components of a URI reference, with presence flags.
struct UriParts
{
    string scheme, authority, path, query, fragment;
    bool hasScheme, hasAuthority, hasQuery, hasFragment;
}

private bool isAlpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool isDigit(char c)
{
    return c >= '0' && c <= '9';
}

/// Splits a URI reference into its components (RFC 3986 appendix B).
UriParts parseUri(string s)
{
    UriParts u;
    size_t i = 0;
    immutable n = s.length;
    if (n > 0 && isAlpha(s[0]))
    {
        size_t j = 1;
        while (j < n && (isAlpha(s[j]) || isDigit(s[j]) || s[j] == '+' || s[j] == '-' || s[j] == '.'))
            j++;
        if (j < n && s[j] == ':')
        {
            u.hasScheme = true;
            u.scheme = s[0 .. j];
            i = j + 1;
        }
    }
    if (i + 1 < n && s[i] == '/' && s[i + 1] == '/')
    {
        i += 2;
        size_t k = i;
        while (k < n && s[k] != '/' && s[k] != '?' && s[k] != '#')
            k++;
        u.hasAuthority = true;
        u.authority = s[i .. k];
        i = k;
    }
    size_t k = i;
    while (k < n && s[k] != '?' && s[k] != '#')
        k++;
    u.path = s[i .. k];
    i = k;
    if (i < n && s[i] == '?')
    {
        i++;
        k = i;
        while (k < n && s[k] != '#')
            k++;
        u.hasQuery = true;
        u.query = s[i .. k];
        i = k;
    }
    if (i < n && s[i] == '#')
    {
        u.hasFragment = true;
        u.fragment = s[i + 1 .. $];
    }
    return u;
}

/// Joins components back into a string (RFC 3986 section 5.3).
string recompose(const UriParts u)
{
    string r;
    if (u.hasScheme)
        r ~= u.scheme ~ ":";
    if (u.hasAuthority)
        r ~= "//" ~ u.authority;
    r ~= u.path;
    if (u.hasQuery)
        r ~= "?" ~ u.query;
    if (u.hasFragment)
        r ~= "#" ~ u.fragment;
    return r;
}

/// RFC 3986 section 5.2.4.
string removeDotSegments(string path)
{
    import std.algorithm.searching : startsWith;

    if (path.length == 0)
        return path;
    string input = path;
    char[] output;
    void popSegment()
    {
        size_t k = output.length;
        while (k > 0 && output[k - 1] != '/')
            k--;
        output = output[0 .. k > 0 ? k - 1 : 0];
    }

    while (input.length > 0)
    {
        if (input.startsWith("../"))
            input = input[3 .. $];
        else if (input.startsWith("./"))
            input = input[2 .. $];
        else if (input.startsWith("/./"))
            input = input[2 .. $];
        else if (input == "/.")
            input = "/";
        else if (input.startsWith("/../"))
        {
            input = input[3 .. $];
            popSegment();
        }
        else if (input == "/..")
        {
            input = "/";
            popSegment();
        }
        else if (input == "." || input == "..")
            input = "";
        else
        {
            size_t k = input[0] == '/' ? 1 : 0;
            while (k < input.length && input[k] != '/')
                k++;
            output ~= input[0 .. k];
            input = input[k .. $];
        }
    }
    return cast(string) output;
}

/// Resolves reference `ref_` against `base` (strict, RFC 3986 section 5.2.2).
string resolve(string ref_, string base)
{
    auto r = parseUri(ref_);
    auto b = parseUri(base);
    UriParts t;
    if (r.hasScheme)
    {
        t = r;
        t.path = removeDotSegments(r.path);
    }
    else
    {
        if (r.hasAuthority)
        {
            t.authority = r.authority;
            t.hasAuthority = true;
            t.path = removeDotSegments(r.path);
            t.query = r.query;
            t.hasQuery = r.hasQuery;
        }
        else
        {
            if (r.path.length == 0)
            {
                t.path = b.path;
                if (r.hasQuery)
                {
                    t.query = r.query;
                    t.hasQuery = true;
                }
                else
                {
                    t.query = b.query;
                    t.hasQuery = b.hasQuery;
                }
            }
            else
            {
                if (r.path[0] == '/')
                    t.path = removeDotSegments(r.path);
                else
                    t.path = removeDotSegments(mergePaths(b, r.path));
                t.query = r.query;
                t.hasQuery = r.hasQuery;
            }
            t.authority = b.authority;
            t.hasAuthority = b.hasAuthority;
        }
        t.scheme = b.scheme;
        t.hasScheme = b.hasScheme;
    }
    t.fragment = r.fragment;
    t.hasFragment = r.hasFragment;
    return recompose(t);
}

private string mergePaths(const UriParts base, string refPath)
{
    if (base.hasAuthority && base.path.length == 0)
        return "/" ~ refPath;
    size_t k = base.path.length;
    while (k > 0 && base.path[k - 1] != '/')
        k--;
    return base.path[0 .. k] ~ refPath;
}

/// Returns `uri` without its fragment; `fragment` receives the (still encoded) fragment.
string splitFragment(string uri, out string fragment, out bool hasFragment)
{
    foreach (i, c; uri)
    {
        if (c == '#')
        {
            fragment = uri[i + 1 .. $];
            hasFragment = true;
            return uri[0 .. i];
        }
    }
    return uri;
}

/// Decodes `%XX` sequences; malformed sequences are kept literally.
string percentDecode(string s)
{
    import std.string : indexOf;

    if (s.indexOf('%') < 0)
        return s;
    static int hexVal(char c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    char[] r;
    for (size_t i = 0; i < s.length; i++)
    {
        if (s[i] == '%' && i + 2 < s.length && hexVal(s[i + 1]) >= 0 && hexVal(s[i + 2]) >= 0)
        {
            r ~= cast(char)(hexVal(s[i + 1]) * 16 + hexVal(s[i + 2]));
            i += 2;
        }
        else
            r ~= s[i];
    }
    return cast(string) r;
}
