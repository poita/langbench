/// Reads tagged JSON (the `toml-test` interchange format) into a `Node` tree.
module toml.jsonreader;

import toml.errors : TomlException;
import toml.node;
import toml.utf8 : appendUtf8, isScalarValue;

/**
 * Parses tagged JSON. A JSON object is a value node when it has exactly the
 * two string members `type` and `value` and `type` names a scalar type;
 * otherwise it is a table. Scalar texts are kept verbatim.
 *
 * Throws: `TomlException` on malformed JSON
 */
Node fromTaggedJson(string json)
{
    auto r = Reader(json);
    r.ws();
    auto n = r.value();
    r.ws();
    if (r.p != json.length)
        r.fail("trailing data");
    return n;
}

private:

struct Pair
{
    string key;
    Node value;
}

struct Reader
{
    string s;
    size_t p;

    noreturn fail(string msg)
    {
        throw new TomlException("invalid tagged JSON: " ~ msg, p);
    }

    void ws()
    {
        while (p < s.length && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r'))
            p++;
    }

    Node value()
    {
        if (p >= s.length)
            fail("unexpected end");
        switch (s[p])
        {
        case '{':
            return object();
        case '[':
            return array();
        case '"':
            return Node.newScalar(Kind.string_, string_());
        default:
            fail("unexpected character");
        }
    }

    Node array()
    {
        p++;
        auto a = Node.newArray(false);
        ws();
        if (p < s.length && s[p] == ']')
        {
            p++;
            return a;
        }
        for (;;)
        {
            ws();
            a.items ~= value();
            ws();
            if (p >= s.length)
                fail("unterminated array");
            if (s[p] == ',')
            {
                p++;
                continue;
            }
            if (s[p] == ']')
            {
                p++;
                return a;
            }
            fail("expected , or ]");
        }
    }

    Node object()
    {
        p++;
        Pair[] pairs;
        ws();
        if (p < s.length && s[p] == '}')
            p++;
        else
            for (;;)
            {
                ws();
                if (p >= s.length || s[p] != '"')
                    fail("expected key");
                auto k = string_();
                ws();
                if (p >= s.length || s[p] != ':')
                    fail("expected :");
                p++;
                ws();
                pairs ~= Pair(k, value());
                ws();
                if (p >= s.length)
                    fail("unterminated object");
                if (s[p] == ',')
                {
                    p++;
                    continue;
                }
                if (s[p] == '}')
                {
                    p++;
                    break;
                }
                fail("expected , or }");
            }

        // Value node?
        if (pairs.length == 2)
        {
            Node typeNode, valueNode;
            foreach (pr; pairs)
            {
                if (pr.key == "type")
                    typeNode = pr.value;
                else if (pr.key == "value")
                    valueNode = pr.value;
            }
            Kind k;
            if (typeNode !is null && valueNode !is null && typeNode.kind == Kind.string_
                    && valueNode.kind == Kind.string_ && kindFromName(typeNode.text, k))
                return Node.newScalar(k, valueNode.text);
        }
        auto t = Node.newTable(Origin.explicit);
        foreach (pr; pairs)
            t.members[pr.key] = pr.value;
        return t;
    }

    uint hex4()
    {
        if (p + 4 > s.length)
            fail("bad \\u escape");
        uint v = 0;
        foreach (i; 0 .. 4)
        {
            immutable c = s[p + i];
            uint d;
            if (c >= '0' && c <= '9')
                d = c - '0';
            else if (c >= 'a' && c <= 'f')
                d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                d = c - 'A' + 10;
            else
                fail("bad \\u escape");
            v = v * 16 + d;
        }
        p += 4;
        return v;
    }

    string string_()
    {
        p++;
        size_t start = p;
        char[] buf;
        bool useBuf = false;
        for (;;)
        {
            while (p < s.length && s[p] != '"' && s[p] != '\\')
                p++;
            if (p >= s.length)
                fail("unterminated string");
            if (s[p] == '"')
            {
                string r = useBuf ? (buf ~= s[start .. p]).idup : s[start .. p];
                p++;
                return r;
            }
            useBuf = true;
            buf ~= s[start .. p];
            p++;
            if (p >= s.length)
                fail("unterminated escape");
            immutable c = s[p++];
            switch (c)
            {
            case '"':
                buf ~= '"';
                break;
            case '\\':
                buf ~= '\\';
                break;
            case '/':
                buf ~= '/';
                break;
            case 'b':
                buf ~= '\b';
                break;
            case 'f':
                buf ~= '\f';
                break;
            case 'n':
                buf ~= '\n';
                break;
            case 'r':
                buf ~= '\r';
                break;
            case 't':
                buf ~= '\t';
                break;
            case 'u':
                uint cp = hex4();
                if (cp >= 0xD800 && cp <= 0xDBFF && p + 1 < s.length && s[p] == '\\' && s[p + 1] == 'u')
                {
                    immutable save = p;
                    p += 2;
                    immutable lo = hex4();
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    else
                        p = save;
                }
                if (!isScalarValue(cp))
                    cp = 0xFFFD;
                appendUtf8(buf, cp);
                break;
            default:
                fail("bad escape");
            }
            start = p;
        }
    }
}
