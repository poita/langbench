/**
 * Parser for the `simulate ... end` block syntax.
 */
module webhooks.simparse;

import webhooks.grammar;
import webhooks.hex;
import webhooks.signature;
import webhooks.simulator;

/// Limits from the block grammar.
enum size_t maxEndpoints = 64;
enum size_t maxEvents = 20_000;
enum size_t maxFilterEntries = 16;
enum size_t maxScriptEntries = 64;

/// Parses a `<filter>`: `*` or 1..16 comma-separated event types.
bool parseFilter(const(ubyte)[] field, out bool wildcard, out const(ubyte)[][] types) @safe pure nothrow
{
    if (field.length == 1 && field[0] == '*')
    {
        wildcard = true;
        return true;
    }
    auto parts = splitOn(field, ',');
    if (parts.length > maxFilterEntries)
        return false;
    foreach (p; parts)
        if (!isName(p))
            return false;
    types = parts;
    return true;
}

/// Parses a `<script>`: 1..64 comma-separated status codes (100..599) or `timeout`.
bool parseScript(const(ubyte)[] field, out ushort[] script) @safe pure nothrow
{
    auto parts = splitOn(field, ',');
    if (parts.length > maxScriptEntries)
        return false;
    auto result = new ushort[parts.length];
    foreach (i, p; parts)
    {
        if (equals(p, "timeout"))
        {
            result[i] = timeoutResponse;
            continue;
        }
        if (p.length != 3)
            return false;
        uint code = 0;
        foreach (b; p)
        {
            if (b < '0' || b > '9')
                return false;
            code = code * 10 + (b - '0');
        }
        if (code < 100 || code > 599)
            return false;
        result[i] = cast(ushort) code;
    }
    script = result;
    return true;
}

private bool parseEndpoint(ref const Fields f, ref Simulation sim, ref bool[const(ubyte)[]] seen)
    @safe pure nothrow
{
    if (f.count != 5 || f.anyEmpty || !isName(f[1]) || f[1] in seen)
        return false;
    Endpoint ep;
    ep.id = f[1];
    if (!parseSecrets(f[2], ep.secrets))
        return false;
    if (!parseFilter(f[3], ep.wildcard, ep.filter))
        return false;
    if (!parseScript(f[4], ep.script))
        return false;
    seen[f[1]] = true;
    sim.endpoints ~= ep;
    return true;
}

private bool parseEvent(ref const Fields f, ref Simulation sim, ref bool[const(ubyte)[]] seen)
    @safe pure nothrow
{
    if (f.count != 5 || f.anyEmpty || !isName(f[1]) || f[1] in seen)
        return false;
    Event ev;
    ev.id = f[1];
    ev.timestampText = f[2];
    if (!parseInt(f[2], ev.timestamp))
        return false;
    if (!isName(f[3]))
        return false;
    ev.type = f[3];
    if (!decodeHexArg(f[4], ev.payload))
        return false;
    seen[f[1]] = true;
    sim.events ~= ev;
    return true;
}

/**
 * Reads the lines of a block (the `simulate` line has already been
 * consumed) up to and including the terminating `end`.
 *
 * On a malformed block the remaining lines up to `end` (or end of input) are
 * consumed unparsed and false is returned. On success the endpoints and
 * events of `sim` are filled in (deliveries are not yet created).
 */
bool parseSimulateBlock(ref LineReader reader, out Simulation sim) @safe pure nothrow
{
    bool good = true;
    bool sawEvent = false;
    bool[const(ubyte)[]] endpointIds;
    bool[const(ubyte)[]] eventIds;

    while (!reader.empty)
    {
        auto line = reader.next();
        if (isBlank(line))
            continue;
        if (equals(line, "end"))
            return good && sim.endpoints.length >= 1;
        if (!good)
            continue;
        const f = splitFields(line);
        if (f.count == 0 || f.anyEmpty)
        {
            good = false;
        }
        else if (equals(f[0], "endpoint"))
        {
            good = !sawEvent && sim.endpoints.length < maxEndpoints
                && parseEndpoint(f, sim, endpointIds);
        }
        else if (equals(f[0], "event"))
        {
            sawEvent = true;
            good = sim.events.length < maxEvents && parseEvent(f, sim, eventIds);
        }
        else
        {
            good = false;
        }
    }
    return false; // end of input before `end`
}
