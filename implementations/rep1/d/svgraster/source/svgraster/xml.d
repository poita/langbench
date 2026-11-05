/// A tiny non-validating XML reader: elements and attributes only.
///
/// Namespace prefixes are stripped from element and attribute names, comments,
/// processing instructions, DOCTYPE and CDATA are skipped, and character data
/// is ignored.
module svgraster.xml;

/// An attribute with its prefix-stripped name and entity-decoded value.
struct Attr
{
    string name;
    string value;
}

/// An element in the parsed tree.
final class Element
{
    /// Tag name with any namespace prefix removed.
    string tag;
    /// Attributes in document order; a repeated name keeps only the last value.
    Attr[] attrs;
    /// Child elements in document order.
    Element[] children;

    /// True if the element has an attribute called `name`.
    bool has(string name) const pure nothrow @safe
    {
        foreach (ref a; attrs)
            if (a.name == name)
                return true;
        return false;
    }

    /// The value of attribute `name`, or `null` if it is absent.
    string attr(string name) const pure nothrow @safe
    {
        foreach (ref a; attrs)
            if (a.name == name)
                return a.value;
        return null;
    }

    private void set(string name, string value) pure nothrow @safe
    {
        foreach (ref a; attrs)
        {
            if (a.name == name)
            {
                a.value = value;
                return;
            }
        }
        attrs ~= Attr(name, value);
    }
}

/// A parsed document: the root element and an `id` lookup table.
struct Document
{
    /// The document element, or `null` if the text contained no start tag.
    Element root;
    /// Map from `id` attribute value to the first element (in document order)
    /// that carries it.
    Element[string] ids;

    /// Look up an element by id; `null` if there is none.
    Element byId(string id) pure nothrow @safe
    {
        if (auto p = id in ids)
            return *p;
        return null;
    }
}

/// Parse `src` into a `Document`. The parser is forgiving: malformed input
/// yields whatever tree could be recovered.
Document parseXml(string src) pure @safe
{
    Document doc;
    doc.root = parseTree(src);
    if (doc.root !is null)
        indexIds(doc.root, doc);
    return doc;
}

private void indexIds(Element e, ref Document doc) pure @safe
{
    if (e.has("id"))
    {
        auto id = e.attr("id");
        if (id !in doc.ids)
            doc.ids[id] = e;
    }
    foreach (c; e.children)
        indexIds(c, doc);
}

private bool startsAt(string s, size_t p, string lit) pure nothrow @nogc @safe
{
    return p + lit.length <= s.length && s[p .. p + lit.length] == lit;
}

private size_t findFrom(string s, size_t p, string lit) pure nothrow @nogc @safe
{
    for (; p + lit.length <= s.length; ++p)
        if (s[p] == lit[0] && s[p .. p + lit.length] == lit)
            return p;
    return s.length;
}

private bool isWs(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

private string stripPrefix(string name) pure nothrow @nogc @safe
{
    foreach_reverse (i, c; name)
        if (c == ':')
            return name[i + 1 .. $];
    return name;
}

private Element parseTree(string s) pure @safe
{
    Element root;
    Element[] stack;
    immutable n = s.length;
    size_t p = 0;
    while (p < n)
    {
        while (p < n && s[p] != '<')
            ++p;
        if (p >= n)
            break;
        if (startsAt(s, p, "<?"))
        {
            p = findFrom(s, p + 2, "?>") + 2;
        }
        else if (startsAt(s, p, "<!--"))
        {
            p = findFrom(s, p + 4, "-->") + 3;
        }
        else if (startsAt(s, p, "<![CDATA["))
        {
            p = findFrom(s, p + 9, "]]>") + 3;
        }
        else if (startsAt(s, p, "<!"))
        {
            p = skipDeclaration(s, p + 2);
        }
        else if (startsAt(s, p, "</"))
        {
            while (p < n && s[p] != '>')
                ++p;
            ++p;
            if (stack.length > 0)
                stack = stack[0 .. $ - 1];
            if (stack.length == 0 && root !is null)
                break;
        }
        else
        {
            ++p;
            size_t q = p;
            while (q < n && !isWs(s[q]) && s[q] != '/' && s[q] != '>')
                ++q;
            auto e = new Element;
            e.tag = stripPrefix(s[p .. q]);
            p = q;
            bool selfClose = false;
            while (p < n)
            {
                while (p < n && isWs(s[p]))
                    ++p;
                if (p >= n)
                    break;
                if (s[p] == '>')
                {
                    ++p;
                    break;
                }
                if (s[p] == '/')
                {
                    selfClose = true;
                    ++p;
                    continue;
                }
                size_t a = p;
                while (p < n && !isWs(s[p]) && s[p] != '=' && s[p] != '>' && s[p] != '/')
                    ++p;
                string name = stripPrefix(s[a .. p]);
                while (p < n && isWs(s[p]))
                    ++p;
                string value;
                if (p < n && s[p] == '=')
                {
                    ++p;
                    while (p < n && isWs(s[p]))
                        ++p;
                    if (p < n && (s[p] == '"' || s[p] == '\''))
                    {
                        immutable quote = s[p];
                        ++p;
                        size_t v = p;
                        while (p < n && s[p] != quote)
                            ++p;
                        value = decodeEntities(s[v .. p]);
                        if (p < n)
                            ++p;
                    }
                    else
                    {
                        size_t v = p;
                        while (p < n && !isWs(s[p]) && s[p] != '>')
                            ++p;
                        value = decodeEntities(s[v .. p]);
                    }
                }
                if (name.length)
                    e.set(name, value);
            }
            if (stack.length > 0)
                stack[$ - 1].children ~= e;
            if (root is null)
                root = e;
            if (selfClose)
            {
                if (stack.length == 0)
                    break;
            }
            else
                stack ~= e;
        }
    }
    return root;
}

/// Skip `<!DOCTYPE ...>` (with an optional `[...]` subset) starting after `<!`.
private size_t skipDeclaration(string s, size_t p) pure nothrow @nogc @safe
{
    int depth = 0;
    char quote = 0;
    for (; p < s.length; ++p)
    {
        immutable c = s[p];
        if (quote)
        {
            if (c == quote)
                quote = 0;
        }
        else if (c == '"' || c == '\'')
            quote = c;
        else if (c == '[')
            ++depth;
        else if (c == ']')
            --depth;
        else if (c == '>' && depth <= 0)
            return p + 1;
    }
    return s.length;
}

/// Resolve `&amp; &lt; &gt; &quot; &apos;` and numeric character references.
/// Other `&...;` sequences are left untouched. Allocates only when the value
/// contains an `&`.
string decodeEntities(string v) pure @safe
{
    bool any = false;
    foreach (c; v)
        if (c == '&')
        {
            any = true;
            break;
        }
    if (!any)
        return v;
    char[] o;
    o.reserve(v.length);
    size_t i = 0;
    while (i < v.length)
    {
        if (v[i] != '&')
        {
            o ~= v[i++];
            continue;
        }
        size_t semi = i + 1;
        while (semi < v.length && semi - i <= 12 && v[semi] != ';')
            ++semi;
        if (semi >= v.length || v[semi] != ';')
        {
            o ~= v[i++];
            continue;
        }
        auto name = v[i + 1 .. semi];
        bool done = true;
        if (name == "amp")
            o ~= '&';
        else if (name == "lt")
            o ~= '<';
        else if (name == "gt")
            o ~= '>';
        else if (name == "quot")
            o ~= '"';
        else if (name == "apos")
            o ~= '\'';
        else if (name.length >= 2 && name[0] == '#')
        {
            uint code = 0;
            bool ok = true;
            if (name[1] == 'x' || name[1] == 'X')
            {
                ok = name.length > 2;
                foreach (c; name[2 .. $])
                {
                    uint d;
                    if (c >= '0' && c <= '9')
                        d = c - '0';
                    else if (c >= 'a' && c <= 'f')
                        d = c - 'a' + 10;
                    else if (c >= 'A' && c <= 'F')
                        d = c - 'A' + 10;
                    else
                    {
                        ok = false;
                        break;
                    }
                    code = code * 16 + d;
                    if (code > 0x10FFFF)
                    {
                        ok = false;
                        break;
                    }
                }
            }
            else
            {
                foreach (c; name[1 .. $])
                {
                    if (c < '0' || c > '9')
                    {
                        ok = false;
                        break;
                    }
                    code = code * 10 + (c - '0');
                    if (code > 0x10FFFF)
                    {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok)
                appendUtf8(o, code);
            else
                done = false;
        }
        else
            done = false;
        if (done)
            i = semi + 1;
        else
            o ~= v[i++];
    }
    return o.idup;
}

private void appendUtf8(ref char[] o, uint c) pure @safe
{
    if (c < 0x80)
        o ~= cast(char) c;
    else if (c < 0x800)
    {
        o ~= cast(char)(0xC0 | (c >> 6));
        o ~= cast(char)(0x80 | (c & 0x3F));
    }
    else if (c < 0x10000)
    {
        o ~= cast(char)(0xE0 | (c >> 12));
        o ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (c & 0x3F));
    }
    else
    {
        o ~= cast(char)(0xF0 | (c >> 18));
        o ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
        o ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (c & 0x3F));
    }
}
