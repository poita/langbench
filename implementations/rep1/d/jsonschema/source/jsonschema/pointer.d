/**
 * JSON Pointer (RFC 6901) evaluation over a $(MREF jsonschema.json.Value) tree.
 */
module jsonschema.pointer;

import jsonschema.json;

/// Unescapes one reference token (`~1` is `/`, `~0` is `~`).
string unescapeToken(string tok)
{
    import std.string : indexOf;

    if (tok.indexOf('~') < 0)
        return tok;
    char[] r;
    for (size_t i = 0; i < tok.length; i++)
    {
        if (tok[i] == '~' && i + 1 < tok.length && tok[i + 1] == '1')
        {
            r ~= '/';
            i++;
        }
        else if (tok[i] == '~' && i + 1 < tok.length && tok[i + 1] == '0')
        {
            r ~= '~';
            i++;
        }
        else
            r ~= tok[i];
    }
    return cast(string) r;
}

/**
 * Follows `pointer` (already percent-decoded; empty or starting with `/`)
 * from `root`. Returns the addressed value, or null if the path does not exist.
 */
const(Value)* evaluatePointer(const(Value)* root, string pointer)
{
    if (pointer.length == 0)
        return root;
    if (pointer[0] != '/')
        return null;
    auto cur = root;
    size_t i = 1;
    for (;;)
    {
        size_t j = i;
        while (j < pointer.length && pointer[j] != '/')
            j++;
        auto tok = unescapeToken(pointer[i .. j]);
        if (cur.kind == Kind.object)
        {
            cur = cur.object.find(tok);
            if (cur is null)
                return null;
        }
        else if (cur.kind == Kind.array)
        {
            if (tok.length == 0 || (tok.length > 1 && tok[0] == '0'))
                return null;
            size_t idx = 0;
            foreach (c; tok)
            {
                if (c < '0' || c > '9' || idx > size_t.max / 20)
                    return null;
                idx = idx * 10 + (c - '0');
            }
            if (idx >= cur.array.length)
                return null;
            cur = &cur.array[idx];
        }
        else
            return null;
        if (j >= pointer.length)
            return cur;
        i = j + 1;
    }
}
