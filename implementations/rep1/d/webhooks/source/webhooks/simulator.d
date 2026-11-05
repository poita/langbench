/**
 * Deterministic webhook delivery simulator.
 *
 * Build a `Simulation` (endpoints + events), call `createDeliveries` to
 * expand and sign deliveries, `run` to execute the retry schedule, and
 * `render` to write the report. `webhooks.simparse` builds a `Simulation`
 * from the textual block syntax.
 */
module webhooks.simulator;

import webhooks.buffer;
import webhooks.heap;
import webhooks.signature;

/// Maximum number of attempts per delivery.
enum ubyte maxAttempts = 8;

/// Seconds to wait after attempt `n` (1-based) before attempt `n + 1`.
immutable long[7] retryDelays = [5, 300, 1800, 7200, 18000, 36000, 36000];

/// Script response meaning "no HTTP response".
enum ushort timeoutResponse = 0;

/// A receiving endpoint.
struct Endpoint
{
    const(ubyte)[] id;
    Secret[] secrets;
    /// True if the filter is `*`.
    bool wildcard;
    /// Event types accepted when not `wildcard`.
    const(ubyte)[][] filter;
    /// Scripted responses: a status code, or `timeoutResponse`.
    ushort[] script;
    /// Index of the next scripted response.
    size_t cursor;
    /// Set once the endpoint answered 410.
    bool disabled;

    /// Does this endpoint receive events of type `type`?
    bool accepts(scope const(ubyte)[] type) const @safe pure nothrow @nogc
    {
        if (wildcard)
            return true;
        foreach (f; filter)
            if (f == type)
                return true;
        return false;
    }

    /// Next scripted response; the last entry repeats forever.
    ushort nextResponse() @safe pure nothrow @nogc
    {
        immutable i = cursor < script.length ? cursor : script.length - 1;
        ++cursor;
        return script[i];
    }
}

/// An event to deliver.
struct Event
{
    const(ubyte)[] id;
    /// Timestamp text exactly as written (used for signing).
    const(ubyte)[] timestampText;
    long timestamp;
    const(ubyte)[] type;
    ubyte[] payload;
}

/// Final state of a delivery.
enum DeliveryStatus : ubyte
{
    pending,
    delivered,
    failed,
    disabled,
}

/// One (event, endpoint) delivery.
struct Delivery
{
    uint event;
    uint endpoint;
    ubyte attempts;
    long lastTime;
    DeliveryStatus status;
    size_t headerOffset;
    size_t headerLength;
}

/// A recorded attempt (indices, not copies).
struct AttemptRecord
{
    uint delivery;
    ubyte number;
    ushort response;
    long time;
}

/// Outcome category for a response.
enum Outcome : ubyte
{
    success,
    failure,
    timeout,
    gone,
}

/// Classifies a script response.
Outcome classify(ushort response) @safe pure nothrow @nogc
{
    if (response == timeoutResponse)
        return Outcome.timeout;
    if (response >= 200 && response <= 299)
        return Outcome.success;
    if (response == 410)
        return Outcome.gone;
    return Outcome.failure;
}

/// The complete state of one simulation.
struct Simulation
{
    Endpoint[] endpoints;
    Event[] events;
    Delivery[] deliveries;
    AttemptRecord[] attempts;
    private ByteSink headers;

    /// The `webhook-signature` header of a delivery.
    const(ubyte)[] header(ref const Delivery d) const @safe pure nothrow @nogc
    {
        return headers.data[d.headerOffset .. d.headerOffset + d.headerLength];
    }

    /**
     * Expands deliveries (event order, then endpoint order) and signs each
     * exactly once with all of its endpoint's secrets.
     */
    void createDeliveries() @safe pure nothrow
    {
        deliveries = null;
        headers = ByteSink.init;
        foreach (ei, ref ev; events)
        {
            foreach (pi, ref ep; endpoints)
            {
                if (!ep.accepts(ev.type))
                    continue;
                Delivery d;
                d.event = cast(uint) ei;
                d.endpoint = cast(uint) pi;
                d.headerOffset = headers.length;
                signHeader(ep.secrets, ev.id, ev.timestampText, ev.payload, headers);
                d.headerLength = headers.length - d.headerOffset;
                deliveries ~= d;
            }
        }
    }

    /// Runs the retry schedule to completion.
    void run() @safe pure nothrow
    {
        attempts = null;
        attempts.reserve(deliveries.length);
        auto heap = SlotHeap(deliveries.length);
        foreach (i, ref d; deliveries)
            heap.push(Slot(events[d.event].timestamp, cast(uint) i));
        // Per-delivery next attempt number (1-based) is d.attempts + 1.
        while (!heap.empty)
        {
            immutable slot = heap.pop();
            auto d = &deliveries[slot.delivery];
            auto ep = &endpoints[d.endpoint];
            if (ep.disabled)
            {
                d.status = DeliveryStatus.disabled;
                continue;
            }
            immutable response = ep.nextResponse();
            immutable number = cast(ubyte)(d.attempts + 1);
            d.attempts = number;
            d.lastTime = slot.time;
            attempts ~= AttemptRecord(slot.delivery, number, response, slot.time);
            final switch (classify(response))
            {
            case Outcome.success:
                d.status = DeliveryStatus.delivered;
                break;
            case Outcome.gone:
                d.status = DeliveryStatus.failed;
                ep.disabled = true;
                break;
            case Outcome.timeout:
            case Outcome.failure:
                if (number >= maxAttempts)
                    d.status = DeliveryStatus.failed;
                else
                    heap.push(Slot(slot.time + retryDelays[number - 1], slot.delivery));
                break;
            }
        }
    }

    /// Writes the `sim`, `attempt` and `delivery` lines to `sink`.
    void render(ref ByteSink sink) const @safe pure nothrow
    {
        sink.put("sim ");
        sink.putInt(attempts.length);
        sink.putChar(' ');
        sink.putInt(deliveries.length);
        sink.putChar('\n');
        foreach (seq, ref a; attempts)
        {
            auto d = &deliveries[a.delivery];
            sink.put("attempt ");
            sink.putInt(seq + 1);
            sink.putChar(' ');
            sink.put(events[d.event].id);
            sink.putChar(' ');
            sink.put(endpoints[d.endpoint].id);
            sink.putChar(' ');
            sink.putInt(a.number);
            sink.putChar(' ');
            sink.putInt(a.time);
            sink.putChar(' ');
            immutable outcome = classify(a.response);
            sink.put(outcomeName(outcome));
            sink.putChar(' ');
            if (outcome == Outcome.timeout)
                sink.putChar('-');
            else
                sink.putInt(a.response);
            sink.putChar('\n');
        }
        foreach (ref d; deliveries)
        {
            sink.put("delivery ");
            sink.put(events[d.event].id);
            sink.putChar(' ');
            sink.put(endpoints[d.endpoint].id);
            sink.putChar(' ');
            sink.put(statusName(d.status));
            sink.putChar(' ');
            sink.putInt(d.attempts);
            sink.putChar(' ');
            if (d.attempts == 0)
                sink.putChar('-');
            else
                sink.putInt(d.lastTime);
            sink.putChar(' ');
            sink.put(header(d));
            sink.putChar('\n');
        }
    }
}

/// Wire name of an outcome.
string outcomeName(Outcome o) @safe pure nothrow @nogc
{
    final switch (o)
    {
    case Outcome.success: return "success";
    case Outcome.failure: return "failure";
    case Outcome.timeout: return "timeout";
    case Outcome.gone: return "gone";
    }
}

/// Wire name of a delivery status.
string statusName(DeliveryStatus s) @safe pure nothrow @nogc
{
    final switch (s)
    {
    case DeliveryStatus.pending: return "pending";
    case DeliveryStatus.delivered: return "delivered";
    case DeliveryStatus.failed: return "failed";
    case DeliveryStatus.disabled: return "disabled";
    }
}
