/**
 * The deterministic delivery simulator.
 *
 * A `simulate` block declares endpoints (secrets, event-type filter, scripted
 * responses) and events. `SimulationBuilder` parses and validates the block
 * line by line; `run` expands it into deliveries, signs each one once, and
 * plays them through a time-ordered queue with the fixed retry schedule.
 *
 * The built `Simulation` holds views into the buffers the block lines came
 * from, so those buffers must outlive it.
 */
module webhooks.simulator;

import webhooks.base64;
import webhooks.buffer;
import webhooks.fields;
import webhooks.heap;
import webhooks.hex;
import webhooks.hmac;
import webhooks.secret;
import webhooks.signature;

/// Maximum number of endpoints in a block.
enum size_t maxEndpoints = 64;
/// Maximum number of events in a block.
enum size_t maxEvents = 20_000;
/// Maximum filter entries / script entries.
enum size_t maxFilterEntries = 16, maxScriptEntries = 64;
/// Maximum attempts per delivery.
enum uint maxAttempts = 8;
/// Delay in seconds after attempt n (1-based) before attempt n+1.
static immutable long[7] retryDelays = [5, 300, 1800, 7200, 18_000, 36_000, 36_000];

/// Marker for a `timeout` response in an endpoint script.
enum ushort timeoutResponse = 0;

/// A simulated receiving endpoint.
struct Endpoint
{
    Bytes id;
    HmacKey[] keys;
    bool wildcard;
    Bytes[] filter;
    ushort[] script; /// status codes 100..599, or `timeoutResponse`
    size_t cursor;
    bool disabled;

    /// Does this endpoint receive events of type `type`?
    bool accepts(Bytes type) const @safe pure nothrow @nogc
    {
        if (wildcard)
            return true;
        foreach (f; filter)
            if (f == type)
                return true;
        return false;
    }
}

/// An event to be delivered.
struct Event
{
    Bytes id;
    Bytes tsText; /// timestamp exactly as written
    long ts;
    Bytes type;
    ubyte[] payload;
}

/// A parsed, valid simulation block.
struct Simulation
{
    Endpoint[] endpoints;
    Event[] events;
}

/// What `SimulationBuilder.feed` reports.
enum Feed
{
    more, /// the line was consumed; keep feeding
    end, /// the terminating `end` line was seen
}

/**
 * Incremental parser for the lines of a `simulate` block (after the
 * `simulate` line itself, blank lines excluded).
 *
 * After the first invalid line the builder only watches for `end`.
 */
struct SimulationBuilder
{
    private Simulation sim;
    private bool failed;
    private bool seenEvent;
    private bool[string] endpointIds;
    private bool[string] eventIds;
    private Bytes[] fieldStorage;
    private Bytes[] pieceStorage;
    private Bytes[] fields;

    /// Consume one non-blank line of the block.
    Feed feed(Bytes line)
    {
        if (equalsString(line, "end"))
            return Feed.end;
        if (failed)
            return Feed.more;
        if (!parseLine(line))
            failed = true;
        return Feed.more;
    }

    /// True if every line so far was valid and at least one endpoint was declared.
    bool valid() const @safe pure nothrow @nogc
    {
        return !failed && sim.endpoints.length > 0;
    }

    /// The parsed block. Only meaningful when `valid`.
    ref Simulation simulation() return @safe pure nothrow @nogc
    {
        return sim;
    }

    private bool parseLine(Bytes line)
    {
        fields = splitOn(line, ' ', fieldStorage);
        foreach (f; fields)
            if (f.length == 0)
                return false;
        if (equalsString(fields[0], "endpoint"))
            return fields.length == 5 && parseEndpoint();
        if (equalsString(fields[0], "event"))
            return fields.length == 5 && parseEvent();
        return false;
    }

    private bool parseEndpoint()
    {
        if (seenEvent || sim.endpoints.length >= maxEndpoints)
            return false;
        Endpoint ep;
        ep.id = fields[1];
        if (!isName(ep.id) || (cast(string) ep.id.idup) in endpointIds)
            return false;
        if (!parseSecrets(fields[2], ep.keys))
            return false;
        if (!parseFilter(fields[3], ep))
            return false;
        if (!parseScript(fields[4], ep.script))
            return false;
        endpointIds[cast(string) ep.id.idup] = true;
        sim.endpoints ~= ep;
        return true;
    }

    private bool parseFilter(Bytes text, ref Endpoint ep)
    {
        if (equalsString(text, "*"))
        {
            ep.wildcard = true;
            return true;
        }
        auto pieces = splitOn(text, ',', pieceStorage);
        if (pieces.length > maxFilterEntries)
            return false;
        foreach (p; pieces)
            if (!isName(p))
                return false;
        ep.filter = pieces.dup;
        return true;
    }

    private bool parseScript(Bytes text, out ushort[] script)
    {
        auto pieces = splitOn(text, ',', pieceStorage);
        if (pieces.length > maxScriptEntries)
            return false;
        auto result = new ushort[pieces.length];
        foreach (i, p; pieces)
        {
            if (equalsString(p, "timeout"))
            {
                result[i] = timeoutResponse;
                continue;
            }
            if (p.length != 3)
                return false;
            foreach (c; p)
                if (c < '0' || c > '9')
                    return false;
            immutable code = (p[0] - '0') * 100 + (p[1] - '0') * 10 + (p[2] - '0');
            if (code < 100 || code > 599)
                return false;
            result[i] = cast(ushort) code;
        }
        script = result;
        return true;
    }

    private bool parseEvent()
    {
        if (sim.events.length >= maxEvents)
            return false;
        Event ev;
        ev.id = fields[1];
        if (!isName(ev.id) || (cast(string) ev.id.idup) in eventIds)
            return false;
        ev.tsText = fields[2];
        if (!parseCanonicalInt(ev.tsText, ev.ts))
            return false;
        ev.type = fields[3];
        if (!isName(ev.type))
            return false;
        if (!decodeHex(fields[4], ev.payload))
            return false;
        seenEvent = true;
        eventIds[cast(string) ev.id.idup] = true;
        sim.events ~= ev;
        return true;
    }
}

private enum Status : ubyte
{
    pending,
    delivered,
    failed,
    disabled,
}

private struct Delivery
{
    uint event;
    uint endpoint;
    size_t headerStart;
    size_t headerEnd;
    long lastTime;
    ubyte attempts;
    Status status;
}

private struct AttemptRecord
{
    long time;
    uint delivery;
    ubyte number;
    ushort response;
}

private immutable string[] statusNames = ["pending", "delivered", "failed", "disabled"];

/**
 * Run the simulation and append its report (`sim A D`, the attempt lines,
 * then the delivery lines) to `output`.
 *
 * Endpoint cursors and disabled flags are consumed, so a `Simulation` can be
 * run only once.
 */
void run(ref Simulation sim, ref OutBuffer output)
{
    // Deliveries: event order, then endpoint order; each signed exactly once.
    Delivery[] deliveries;
    OutBuffer headers;
    foreach (ei, ref ev; sim.events)
    {
        foreach (pi, ref ep; sim.endpoints)
        {
            if (!ep.accepts(ev.type))
                continue;
            Delivery d;
            d.event = cast(uint) ei;
            d.endpoint = cast(uint) pi;
            d.headerStart = headers.length;
            putSignatureHeader(headers, ep.keys, ev.id, ev.tsText, ev.payload);
            d.headerEnd = headers.length;
            deliveries ~= d;
        }
    }

    auto initial = new TimedItem[deliveries.length];
    foreach (i, ref d; deliveries)
        initial[i] = TimedItem(sim.events[d.event].ts, cast(uint) i);
    auto queue = MinHeap.heapify(initial);

    AttemptRecord[] attempts;
    while (!queue.empty)
    {
        immutable item = queue.pop();
        auto d = &deliveries[item.id];
        auto ep = &sim.endpoints[d.endpoint];
        if (ep.disabled)
        {
            d.status = Status.disabled;
            continue;
        }
        immutable idx = ep.cursor < ep.script.length ? ep.cursor : ep.script.length - 1;
        immutable response = ep.script[idx];
        ++ep.cursor;
        ++d.attempts;
        d.lastTime = item.time;
        attempts ~= AttemptRecord(item.time, item.id, d.attempts, response);

        if (response >= 200 && response <= 299)
            d.status = Status.delivered;
        else if (response == 410)
        {
            d.status = Status.failed;
            ep.disabled = true;
        }
        else if (d.attempts == maxAttempts)
            d.status = Status.failed;
        else
            queue.push(TimedItem(item.time + retryDelays[d.attempts - 1], item.id));
    }

    output.put("sim ");
    output.putInt(attempts.length);
    output.put(cast(ubyte) ' ');
    output.putInt(deliveries.length);
    output.put(cast(ubyte) '\n');

    foreach (seq, ref a; attempts)
    {
        auto d = &deliveries[a.delivery];
        output.put("attempt ");
        output.putInt(seq + 1);
        output.put(cast(ubyte) ' ');
        output.put(sim.events[d.event].id);
        output.put(cast(ubyte) ' ');
        output.put(sim.endpoints[d.endpoint].id);
        output.put(cast(ubyte) ' ');
        output.putInt(a.number);
        output.put(cast(ubyte) ' ');
        output.putInt(a.time);
        output.put(cast(ubyte) ' ');
        if (a.response == timeoutResponse)
            output.put("timeout -");
        else
        {
            output.put(a.response >= 200 && a.response <= 299 ? "success"
                    : a.response == 410 ? "gone" : "failure");
            output.put(cast(ubyte) ' ');
            output.putInt(a.response);
        }
        output.put(cast(ubyte) '\n');
    }

    Bytes headerBytes = headers.data;
    foreach (ref d; deliveries)
    {
        output.put("delivery ");
        output.put(sim.events[d.event].id);
        output.put(cast(ubyte) ' ');
        output.put(sim.endpoints[d.endpoint].id);
        output.put(cast(ubyte) ' ');
        output.put(statusNames[d.status]);
        output.put(cast(ubyte) ' ');
        output.putInt(d.attempts);
        output.put(cast(ubyte) ' ');
        if (d.attempts == 0)
            output.put(cast(ubyte) '-');
        else
            output.putInt(d.lastTime);
        output.put(cast(ubyte) ' ');
        output.put(headerBytes[d.headerStart .. d.headerEnd]);
        output.put(cast(ubyte) '\n');
    }
}
