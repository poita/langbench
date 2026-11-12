/**
 * Reader for the `simulate` block of the command protocol.
 *
 * ---
 * simulate
 * endpoint <ep-id> <secrets> <filter> <script>
 * event <ev-id> <ts> <type> <payload-hex>
 * end
 * ---
 */
module webhooks.blockparser;

import webhooks.fields;
import webhooks.hex;
import webhooks.simulator;

/// Most endpoints in a block.
enum size_t maxEndpoints = 64;
/// Most events in a block.
enum size_t maxEvents = 20_000;
/// Most event types in a filter.
enum size_t maxFilterTypes = 16;
/// Most responses in a script.
enum size_t maxScriptLength = 64;

private immutable ubyte[] endKeyword = cast(immutable(ubyte)[]) "end";

private bool parseScript(const(ubyte)[] field, out Response[] script) pure nothrow @safe
{
    Response[] result;
    foreach (entry; splitCommas(field))
    {
        if (result.length == maxScriptLength)
            return false;
        if (entry == cast(const(ubyte)[]) "timeout")
            result ~= Response.timeout;
        else if (entry.length == 3 && entry[0] >= '1' && entry[0] <= '5'
                && entry[1] >= '0' && entry[1] <= '9' && entry[2] >= '0' && entry[2] <= '9')
            result ~= Response(cast(ushort)((entry[0] - '0') * 100 + (entry[1] - '0') * 10 + entry[2] - '0'));
        else
            return false;
    }
    script = result;
    return result.length > 0;
}

private bool parseFilter(const(ubyte)[] field, out bool matchAll, out string[] filter) pure nothrow @safe
{
    if (field == cast(const(ubyte)[]) "*")
    {
        matchAll = true;
        return true;
    }
    string[] result;
    foreach (entry; splitCommas(field))
    {
        if (result.length == maxFilterTypes || !isName(entry))
            return false;
        result ~= toText(entry);
    }
    filter = result;
    return true;
}

private string toText(const(ubyte)[] bytes) pure nothrow @trusted
{
    return cast(string) bytes.idup;
}

private bool parseEndpoint(const(ubyte)[][] f, out Endpoint endpoint) pure nothrow @safe
{
    if (f.length != 5 || !isName(f[1]))
        return false;
    Endpoint e;
    e.id = toText(f[1]);
    if (!parseSecretsField(f[2], e.secrets) || !parseFilter(f[3], e.matchAll, e.filter)
            || !parseScript(f[4], e.script))
        return false;
    endpoint = e;
    return true;
}

private bool parseEvent(const(ubyte)[][] f, out Event event) pure nothrow @safe
{
    if (f.length != 5 || !isName(f[1]) || !isName(f[3]))
        return false;
    Event ev;
    ev.id = toText(f[1]);
    ev.timestampText = toText(f[2]);
    ubyte[] payload;
    if (!parseInt(f[2], ev.timestamp) || !parseHexField(f[4], payload))
        return false;
    ev.type = toText(f[3]);
    ev.payload = (() @trusted => cast(immutable) payload)();
    event = ev;
    return true;
}

/**
 * Reads the lines of a block (the opening `simulate` line has already been
 * consumed) up to and including the closing `end`.
 *
 * If a line violates the block grammar, the remaining lines are still
 * consumed up to the closing `end` (or the end of input) so that the caller
 * can resume with the next command.
 *
 * Params:
 *   reader = source of (non-blank) lines
 *   scenario = receives the parsed block when the result is `true`
 * Returns: `true` if the block is well formed.
 */
bool readBlock(ref LineReader reader, out Scenario scenario) pure nothrow @safe
{
    Scenario sc;
    bool valid = true;
    bool sawEvent = false;
    bool closed = false;
    bool[string] endpointIds;
    bool[string] eventIds;

    const(ubyte)[] line;
    while (reader.next(line))
    {
        if (line == endKeyword)
        {
            closed = true;
            break;
        }
        if (!valid)
            continue; // skipping to `end`

        const(ubyte)[][] f;
        if (!splitFields(line, 5, f))
        {
            valid = false;
            continue;
        }
        if (f[0] == cast(const(ubyte)[]) "endpoint")
        {
            Endpoint e;
            if (sawEvent || sc.endpoints.length == maxEndpoints || !parseEndpoint(f, e)
                    || e.id in endpointIds)
            {
                valid = false;
                continue;
            }
            endpointIds[e.id] = true;
            sc.endpoints ~= e;
        }
        else if (f[0] == cast(const(ubyte)[]) "event")
        {
            Event ev;
            sawEvent = true;
            if (sc.events.length == maxEvents || !parseEvent(f, ev) || ev.id in eventIds)
            {
                valid = false;
                continue;
            }
            eventIds[ev.id] = true;
            sc.events ~= ev;
        }
        else
            valid = false;
    }
    if (!closed || !valid || sc.endpoints.length == 0)
        return false;
    scenario = sc;
    return true;
}

version (unittest)
{
    private bool parse(string text, out Scenario sc) @trusted
    {
        auto reader = LineReader(cast(const(ubyte)[]) text);
        return readBlock(reader, sc);
    }
}

@safe unittest
{
    Scenario sc;
    assert(parse("endpoint a c2VjcmV0 * 200\nevent e 0 t -\nend\n", sc));
    assert(sc.endpoints.length == 1 && sc.events.length == 1);
    assert(sc.endpoints[0].matchAll);
    assert(sc.events[0].payload.length == 0 && sc.events[0].timestampText == "0");

    assert(parse("endpoint a c2VjcmV0 x,y 500,timeout,200\n\n   \nend", sc));
    assert(sc.endpoints[0].filter == ["x", "y"]);
    assert(sc.endpoints[0].script == [Response(500), Response.timeout, Response(200)]);
    assert(sc.events.length == 0);
}

@safe unittest
{
    Scenario sc;
    assert(!parse("end\n", sc)); // no endpoint
    assert(!parse("endpoint a c2VjcmV0 * 200\n", sc)); // no end
    assert(!parse("endpoint a c2VjcmV0 * 200\nendpoint a c2VjcmV0 * 200\nend", sc)); // duplicate
    assert(!parse("endpoint a c2VjcmV0 * 200\nevent e 0 t -\nendpoint b c2VjcmV0 * 200\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 200\nevent e 0 t -\nevent e 1 t -\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 099\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 600\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 0200\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 *,x 200\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 x, 200\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 200,\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 200\nsimulate\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 200\nevent e 007 t -\nend", sc));
    assert(!parse("endpoint a c2VjcmV0 * 200\nend ", sc)); // not exactly `end`
}

// After a violation the reader resumes after the first exact `end`.
@trusted unittest
{
    auto reader = LineReader(cast(const(ubyte)[]) "bogus\nendpoint\nend\nsha256 -\n");
    Scenario sc;
    assert(!readBlock(reader, sc));
    const(ubyte)[] line;
    assert(reader.next(line) && line == cast(const(ubyte)[]) "sha256 -");
}

@safe unittest
{
    import std.conv : to;

    string text = "endpoint a c2VjcmV0 * 200\n";
    foreach (i; 0 .. maxEvents)
        text ~= "event e" ~ i.to!string ~ " 0 t -\n";
    Scenario sc;
    assert(parse(text ~ "end\n", sc) && sc.events.length == maxEvents);
    assert(!parse(text ~ "event extra 0 t -\nend\n", sc));

    string eps;
    foreach (i; 0 .. maxEndpoints)
        eps ~= "endpoint p" ~ i.to!string ~ " c2VjcmV0 * 200\n";
    assert(parse(eps ~ "end\n", sc) && sc.endpoints.length == maxEndpoints);
    assert(!parse(eps ~ "endpoint extra c2VjcmV0 * 200\nend\n", sc));
}
