/// A tiny non-validating XML reader: elements and attributes only.
module svgraster.xml;

import std.string : indexOf;
import std.ascii : isWhite, isDigit, isHexDigit;

/// An element of the parsed document tree.
final class Element
{
    /// Tag name with any namespace prefix removed.
    string tag;
    /// Attributes keyed by name with the namespace prefix removed. If a name
    /// occurs twice the last occurrence wins. `xmlns` declarations are dropped.
    string[string] attrs;
    /// Child elements in document order. Character data is discarded.
    Element[] children;
    /// The enclosing element, or `null` for the document element.
    Element parent;

    /// The value of attribute `name`, or `null` if it is absent.
    string get(string name) const
    {
        if (auto p = name in attrs)
            return *p;
        return null;
    }
}

/// Thrown for input that is not usable XML.
class XmlException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// Parse `src` and return the document element (the first start tag).
/// Throws: `XmlException` if the text contains no element.
Element parseXml(const(char)[] src)
{
    Element root, cur;
    size_t i = 0;
    immutable n = src.length;

    while (i < n)
    {
        immutable lt = src.indexOf('<', i);
        if (lt < 0)
            break;
        i = lt;
        if (startsWith(src, i, "<?"))
        {
            i = skipPast(src, i + 2, "?>");
        }
        else if (startsWith(src, i, "<!--"))
        {
            i = skipPast(src, i + 4, "-->");
        }
        else if (startsWith(src, i, "<![CDATA["))
        {
            i = skipPast(src, i + 9, "]]>");
        }
        else if (startsWith(src, i, "<!"))
        {
            i = skipDeclaration(src, i + 2);
        }
        else if (startsWith(src, i, "</"))
        {
            i = skipPast(src, i + 2, ">");
            if (cur !is null)
                cur = cur.parent;
        }
        else
        {
            ++i;
            auto el = new Element;
            size_t j = i;
            while (j < n && !isWhite(src[j]) && src[j] != '>' && src[j] != '/')
                ++j;
            el.tag = stripPrefix(src[i .. j].idup);
            i = j;
            bool selfClosing = false;
            parseAttributes(src, i, el, selfClosing);
            if (root is null)
                root = el;
            else if (cur !is null)
            {
                el.parent = cur;
                cur.children ~= el;
            }
            else
            {
                // Content after the document element has closed: ignore.
                continue;
            }
            if (!selfClosing)
                cur = el;
            else if (cur is null)
                break; // the document element was empty
        }
    }
    if (root is null)
        throw new XmlException("no document element");
    return root;
}

private bool startsWith(const(char)[] s, size_t i, string prefix)
{
    return s.length - i >= prefix.length && s[i .. i + prefix.length] == prefix;
}

private size_t skipPast(const(char)[] s, size_t from, string terminator)
{
    immutable p = s[from .. $].indexOf(terminator);
    return p < 0 ? s.length : from + p + terminator.length;
}

/// Skip `<!DOCTYPE ...>` including an internal `[...]` subset.
private size_t skipDeclaration(const(char)[] s, size_t i)
{
    int depth = 0;
    char quote = 0;
    while (i < s.length)
    {
        immutable ch = s[i++];
        if (quote)
        {
            if (ch == quote)
                quote = 0;
        }
        else if (ch == '"' || ch == '\'')
            quote = ch;
        else if (ch == '[')
            ++depth;
        else if (ch == ']')
            --depth;
        else if (ch == '>' && depth <= 0)
            break;
        else if (ch == '<' && startsWith(s, i - 1, "<!--"))
            i = skipPast(s, i + 3, "-->");
    }
    return i;
}

private string stripPrefix(string name)
{
    immutable c = name.indexOf(':');
    return c < 0 ? name : name[c + 1 .. $];
}

private void parseAttributes(const(char)[] s, ref size_t i, Element el, ref bool selfClosing)
{
    immutable n = s.length;
    while (i < n)
    {
        while (i < n && isWhite(s[i]))
            ++i;
        if (i >= n)
            return;
        if (s[i] == '>')
        {
            ++i;
            return;
        }
        if (s[i] == '/')
        {
            selfClosing = true;
            ++i;
            continue;
        }
        // attribute name
        size_t j = i;
        while (j < n && !isWhite(s[j]) && s[j] != '=' && s[j] != '>' && s[j] != '/')
            ++j;
        immutable rawName = s[i .. j].idup;
        i = j;
        while (i < n && isWhite(s[i]))
            ++i;
        string value;
        if (i < n && s[i] == '=')
        {
            ++i;
            while (i < n && isWhite(s[i]))
                ++i;
            if (i < n && (s[i] == '"' || s[i] == '\''))
            {
                immutable q = s[i];
                ++i;
                j = i;
                while (j < n && s[j] != q)
                    ++j;
                value = decodeEntities(s[i .. j]);
                i = j < n ? j + 1 : n;
            }
        }
        if (rawName.length == 0)
        {
            ++i; // stray character: make progress
            continue;
        }
        if (rawName == "xmlns" || (rawName.length > 6 && rawName[0 .. 6] == "xmlns:"))
            continue;
        el.attrs[stripPrefix(rawName)] = value;
    }
}

/// Resolve the five predefined entities and numeric character references;
/// any other `&...;` is left unchanged.
string decodeEntities(const(char)[] s)
{
    if (s.indexOf('&') < 0)
        return s.idup;
    import std.array : appender;

    auto o = appender!string;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] != '&')
        {
            o.put(s[i++]);
            continue;
        }
        immutable semi = s[i .. $].indexOf(';');
        if (semi < 0)
        {
            o.put(s[i++]);
            continue;
        }
        auto name = s[i + 1 .. i + semi];
        bool done = true;
        switch (name)
        {
        case "amp":  o.put('&');  break;
        case "lt":   o.put('<');  break;
        case "gt":   o.put('>');  break;
        case "quot": o.put('"');  break;
        case "apos": o.put('\''); break;
        default:
            dchar cp;
            if (numericReference(name, cp))
                o.put(cp);
            else
                done = false;
        }
        if (done)
            i += semi + 1;
        else
            o.put(s[i++]);
    }
    return o.data;
}

private bool numericReference(const(char)[] name, out dchar cp)
{
    if (name.length < 2 || name[0] != '#')
        return false;
    uint base = 10;
    auto digits = name[1 .. $];
    if (digits[0] == 'x')
    {
        base = 16;
        digits = digits[1 .. $];
    }
    if (digits.length == 0 || digits.length > 8)
        return false;
    uint v = 0;
    foreach (ch; digits)
    {
        uint dv;
        if (isDigit(ch))
            dv = ch - '0';
        else if (base == 16 && isHexDigit(ch))
            dv = (ch | 0x20) - 'a' + 10;
        else
            return false;
        v = v * base + dv;
    }
    if (v > 0x10FFFF || (v >= 0xD800 && v < 0xE000))
        return false;
    cp = cast(dchar) v;
    return true;
}

unittest
{
    auto root = parseXml(`<?xml version="1.0"?>
<!DOCTYPE svg [ <!ENTITY x "<y>"> ]>
<!-- c -->
<svg:svg xmlns:svg="http://www.w3.org/2000/svg" a = 'x&amp;y' b="1>2" a="last">
  <![CDATA[ <not-an-element/> ]]>
  <svg:g xlink:href="#q"/>
  <g></g>
</svg:svg>`);
    assert(root.tag == "svg");
    assert(root.get("a") == "last");
    assert(root.get("b") == "1>2");
    assert(root.get("xmlns") is null);
    assert(root.children.length == 2);
    assert(root.children[0].get("href") == "#q");
    assert(root.children[1].parent is root);
}

unittest
{
    assert(decodeEntities("a&amp;b&lt;&#65;&#x42;&bogus;&") == "a&b<AB&bogus;&");
    import std.exception : assertThrown;

    assertThrown!XmlException(parseXml("no elements here"));
}
