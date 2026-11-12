/// Formatting of result blocks for `results.txt` (SPEC §19).
module tessera.render;

import std.array : Appender;
import std.conv : to;

import tessera.errors;
import tessera.value;

/// Start a block: `[k] <status>` and a line feed.
void statusLine(ref Appender!string o, size_t lineNo, const(char)[] status) @safe pure nothrow
{
    o.put('[');
    o.put(lineNo.to!string);
    o.put("] ");
    o.put(status);
    o.put('\n');
}

/// A whole block for a failed command.
void errorBlock(ref Appender!string o, size_t lineNo, ErrorKind kind) @safe pure nothrow
{
    statusLine(o, lineNo, "error " ~ errorName(kind));
}

/// A payload line: two spaces then `text`.
void payloadLine(ref Appender!string o, const(char)[] text) @safe pure nothrow
{
    o.put("  ");
    o.put(text);
    o.put('\n');
}

/// A `"key" = document` line (or just `"key"` when `doc` is `null`).
void keyLine(ref Appender!string o, const(char)[] key, const(Value)* doc) @safe pure nothrow
{
    o.put("  ");
    renderString(key, o);
    if (doc !is null)
    {
        o.put(" = ");
        render(*doc, o);
    }
    o.put('\n');
}

@system pure nothrow unittest
{
    Appender!string o;
    statusLine(o, 12, "ok begin");
    payloadLine(o, "pages 2");
    errorBlock(o, 3, ErrorKind.noTxn);
    auto v = Value.integer(2);
    keyLine(o, "b", &v);
    keyLine(o, "c\n", null);
    assert(o[] == "[12] ok begin\n  pages 2\n[3] error no-txn\n  \"b\" = 2\n  \"c\\n\"\n");
}
