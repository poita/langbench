/**
 * Parsing and validation of `simulate` block lines.
 */
module webhooks.simparse;

import webhooks.grammar;
import webhooks.hex;
import webhooks.secret;
import webhooks.signature : parseCanonicalInt;
import webhooks.simulator;

/// Most endpoints in a block.
enum maxEndpoints = 64;
/// Most events in a block.
enum maxEvents = 20_000;

private enum maxFilterTypes = 16;
private enum maxScriptLength = 64;

/**
 * Accumulates the lines of a `simulate` block, validating each.
 *
 * Slices stored in the result point into the buffer the fields came from.
 */
struct BlockBuilder
{
    private Endpoint[] endpoints_;
    private Event[] events_;
    private bool[const(ubyte)[]] endpointIds;
    private bool[const(ubyte)[]] eventIds;

    /// Number of endpoints accepted so far.
    @property size_t endpointCount() const @safe pure nothrow @nogc
    {
        return endpoints_.length;
    }

    /// Adds an `endpoint <id> <secrets> <filter> <script>` line.
    /// Returns false if the line (or its position in the block) is invalid.
    bool addEndpoint(ref const Fields f) @safe pure nothrow
    {
        if (!f.has(5) || events_.length != 0 || endpoints_.length == maxEndpoints)
            return false;
        Endpoint ep;
        ep.id = f.item[1];
        if (!isName(ep.id) || ep.id in endpointIds)
            return false;
        if (!parseSecretList(f.item[2], ep.keys))
            return false;
        if (!parseFilter(f.item[3], ep.wildcard, ep.types))
            return false;
        if (!parseScript(f.item[4], ep.script))
            return false;
        endpointIds[ep.id] = true;
        endpoints_ ~= ep;
        return true;
    }

    /// Adds an `event <id> <ts> <type> <payload-hex>` line.
    /// Returns false if the line (or its position in the block) is invalid.
    bool addEvent(ref const Fields f) @safe pure nothrow
    {
        if (!f.has(5) || events_.length == maxEvents)
            return false;
        Event ev;
        ev.id = f.item[1];
        if (!isName(ev.id) || ev.id in eventIds)
            return false;
        ev.timestampText = f.item[2];
        if (!parseCanonicalInt(ev.timestampText, ev.timestamp))
            return false;
        ev.type = f.item[3];
        if (!isName(ev.type))
            return false;
        ubyte[] payload;
        if (!decodeHex(f.item[4], payload))
            return false;
        ev.payload = payload;
        eventIds[ev.id] = true;
        events_ ~= ev;
        return true;
    }

    /// The finished simulation; null-valid only if at least one endpoint exists.
    Simulation build() @safe pure nothrow @nogc
    {
        return Simulation(endpoints_, events_);
    }
}

private bool parseFilter(const(ubyte)[] text, out bool wildcard, out const(ubyte)[][] types)
    @safe pure nothrow
{
    if (text.length == 1 && text[0] == '*')
    {
        wildcard = true;
        return true;
    }
    const(ubyte)[][] result;
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < text.length && text[end] != ',')
            end++;
        if (result.length == maxFilterTypes || !isName(text[start .. end]))
            return false;
        result ~= text[start .. end];
        if (end == text.length)
            break;
        start = end + 1;
    }
    types = result;
    return true;
}

private bool parseScript(scope const(ubyte)[] text, out Response[] script) @safe pure nothrow
{
    Response[] result;
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < text.length && text[end] != ',')
            end++;
        if (result.length == maxScriptLength)
            return false;
        auto item = text[start .. end];
        if (equals(item, "timeout"))
            result ~= timeoutResponse;
        else if (item.length == 3 && item[0] >= '1' && item[0] <= '5'
            && item[1] >= '0' && item[1] <= '9' && item[2] >= '0' && item[2] <= '9')
            result ~= cast(Response)((item[0] - '0') * 100 + (item[1] - '0') * 10 + (item[2] - '0'));
        else
            return false;
        if (end == text.length)
            break;
        start = end + 1;
    }
    script = result;
    return true;
}
