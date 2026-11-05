/**
 * The deterministic webhook delivery simulator.
 *
 * A `Simulation` is a set of endpoints (each with a scripted sequence of
 * responses) and a set of events. `run` signs one delivery per matching
 * (event, endpoint) pair, then replays attempts and retries in time order on
 * the fixed Standard Webhooks retry schedule.
 */
module webhooks.simulator;

import webhooks.hmac;
import webhooks.outbuf;
import webhooks.signature;

/// Most attempts a delivery makes (the first plus seven retries).
enum maxAttempts = 8;

/// Seconds between attempt `n` and attempt `n + 1` (index `n - 1`).
immutable long[7] retryDelays = [5, 300, 1800, 7200, 18000, 36000, 36000];

/// A scripted endpoint response: an HTTP status code, or `timeout`.
alias Response = ushort;
/// The script value standing for a timeout.
enum Response timeoutResponse = 0;

/// A receiving endpoint.
struct Endpoint
{
    /// Endpoint id.
    const(ubyte)[] id;
    /// Active signing keys, in order.
    HmacKey[] keys;
    /// Deliver every event regardless of type.
    bool wildcard;
    /// Event types accepted when not a wildcard.
    const(ubyte)[][] types;
    /// Responses, consumed one per attempt; the last repeats forever.
    Response[] script;

    /// Whether an event of the given type is delivered to this endpoint.
    bool accepts(scope const(ubyte)[] eventType) const @safe pure nothrow @nogc
    {
        if (wildcard)
            return true;
        foreach (t; types)
            if (t == eventType)
                return true;
        return false;
    }
}

/// An event to deliver.
struct Event
{
    /// Event id (sent as `webhook-id`).
    const(ubyte)[] id;
    /// Timestamp text exactly as given (sent as `webhook-timestamp`).
    const(ubyte)[] timestampText;
    /// Enqueue time, in seconds.
    long timestamp;
    /// Event type, matched against endpoint filters.
    const(ubyte)[] type;
    /// Request body.
    const(ubyte)[] payload;
}

/// Final state of a delivery.
enum DeliveryStatus : ubyte
{
    pending,
    delivered,
    failed,
    disabled,
}

/// Name used in the output (`delivered`, `failed`, `disabled`).
string statusName(DeliveryStatus s) @safe pure nothrow @nogc
{
    final switch (s)
    {
    case DeliveryStatus.pending:
        return "pending";
    case DeliveryStatus.delivered:
        return "delivered";
    case DeliveryStatus.failed:
        return "failed";
    case DeliveryStatus.disabled:
        return "disabled";
    }
}

/// One (event, endpoint) pair and how its delivery ended.
struct Delivery
{
    /// Index into `Simulation.events`.
    uint event;
    /// Index into `Simulation.endpoints`.
    uint endpoint;
    /// Number of attempts made (0..8).
    ubyte attempts;
    /// How the delivery ended.
    DeliveryStatus status;
    /// Scheduled time of the last attempt made (valid if `attempts > 0`).
    long lastTime;
    /// Location of the signature header in `SimulationReport.headers`.
    size_t headerOffset;
    /// ditto
    size_t headerLength;
}

/// One attempt, as recorded in processing order.
struct AttemptRecord
{
    /// Delivery number.
    uint delivery;
    /// 1-based attempt number within the delivery.
    ubyte number;
    /// The endpoint's scripted response.
    Response response;
    /// Scheduled time.
    long time;
}

/// Outcome of one attempt, derived from the response.
enum Outcome : ubyte
{
    success,
    failure,
    timeout,
    gone,
}

/// Classifies a response.
Outcome outcomeOf(Response r) @safe pure nothrow @nogc
{
    if (r == timeoutResponse)
        return Outcome.timeout;
    if (r >= 200 && r <= 299)
        return Outcome.success;
    if (r == 410)
        return Outcome.gone;
    return Outcome.failure;
}

/// The result of running a simulation.
struct SimulationReport
{
    /// The endpoints the report refers to.
    const(Endpoint)[] endpoints;
    /// The events the report refers to.
    const(Event)[] events;
    /// Attempts in processing order.
    AttemptRecord[] attempts;
    /// Deliveries in creation order.
    Delivery[] deliveries;
    /// Concatenated signature header texts.
    ubyte[] headers;

    /// The signature header of delivery `d`.
    const(ubyte)[] header(ref const Delivery d) const @safe pure nothrow @nogc
    {
        return headers[d.headerOffset .. d.headerOffset + d.headerLength];
    }

    /// Appends the `sim ...` block (header line, attempts, deliveries).
    void write(ref OutBuf o) const @safe pure nothrow
    {
        o.put("sim ");
        o.putInt(attempts.length);
        o.putByte(' ');
        o.putInt(deliveries.length);
        o.putByte('\n');
        foreach (seq, ref a; attempts)
        {
            const d = &deliveries[a.delivery];
            o.put("attempt ");
            o.putInt(seq + 1);
            o.putByte(' ');
            o.put(events[d.event].id);
            o.putByte(' ');
            o.put(endpoints[d.endpoint].id);
            o.putByte(' ');
            o.putInt(a.number);
            o.putByte(' ');
            o.putInt(a.time);
            final switch (outcomeOf(a.response))
            {
            case Outcome.success:
                o.put(" success ");
                break;
            case Outcome.failure:
                o.put(" failure ");
                break;
            case Outcome.timeout:
                o.put(" timeout ");
                break;
            case Outcome.gone:
                o.put(" gone ");
                break;
            }
            if (a.response == timeoutResponse)
                o.putByte('-');
            else
                o.putInt(a.response);
            o.putByte('\n');
        }
        foreach (ref d; deliveries)
        {
            o.put("delivery ");
            o.put(events[d.event].id);
            o.putByte(' ');
            o.put(endpoints[d.endpoint].id);
            o.putByte(' ');
            o.put(statusName(d.status));
            o.putByte(' ');
            o.putInt(d.attempts);
            o.putByte(' ');
            if (d.attempts == 0)
                o.putByte('-');
            else
                o.putInt(d.lastTime);
            o.putByte(' ');
            o.put(header(d));
            o.putByte('\n');
        }
    }
}

/// A scheduled attempt: ordered by time, then delivery number.
private struct Pending
{
    long time;
    uint delivery;

    bool before(ref const Pending o) const @safe pure nothrow @nogc
    {
        return time < o.time || (time == o.time && delivery < o.delivery);
    }
}

/// Binary min-heap over reserved storage.
private struct PendingHeap
{
    Pending[] items;
    size_t length;

    this(Pending[] initial) @safe pure nothrow @nogc
    {
        items = initial;
        length = initial.length;
        for (size_t i = length / 2; i-- > 0;)
            siftDown(i);
    }

    bool less(size_t a, size_t b) const @safe pure nothrow @nogc
    {
        return items[a].before(items[b]);
    }

    void siftDown(size_t i) @safe pure nothrow @nogc
    {
        while (true)
        {
            size_t l = 2 * i + 1;
            if (l >= length)
                return;
            size_t m = l;
            if (l + 1 < length && less(l + 1, l))
                m = l + 1;
            if (!less(m, i))
                return;
            auto t = items[i];
            items[i] = items[m];
            items[m] = t;
            i = m;
        }
    }

    void push(Pending p) @safe pure nothrow @nogc
    {
        size_t i = length++;
        items[i] = p;
        while (i > 0)
        {
            immutable parent = (i - 1) / 2;
            if (!less(i, parent))
                break;
            auto t = items[i];
            items[i] = items[parent];
            items[parent] = t;
            i = parent;
        }
    }

    Pending pop() @safe pure nothrow @nogc
    {
        auto top = items[0];
        items[0] = items[--length];
        siftDown(0);
        return top;
    }
}

/// Endpoints and events to simulate.
struct Simulation
{
    Endpoint[] endpoints;
    Event[] events;

    /**
     * Runs the simulation.
     *
     * Deliveries are created in event order, then endpoint order, and signed
     * once each. Attempts are processed in `(time, delivery number)` order.
     * An endpoint that answers 410 is disabled from then on.
     */
    SimulationReport run() const @safe pure nothrow
    {
        SimulationReport report;
        report.endpoints = endpoints;
        report.events = events;

        OutBuf headerText;
        foreach (ei, ref ev; events)
            foreach (pi, ref ep; endpoints)
            {
                if (!ep.accepts(ev.type))
                    continue;
                Delivery d;
                d.event = cast(uint) ei;
                d.endpoint = cast(uint) pi;
                d.headerOffset = headerText.length;
                appendSignatureHeader(headerText, ep.keys, ev.id, ev.timestampText, ev.payload);
                d.headerLength = headerText.length - d.headerOffset;
                report.deliveries ~= d;
            }
        report.headers = headerText.data.dup;

        auto initial = new Pending[report.deliveries.length];
        foreach (i, ref d; report.deliveries)
            initial[i] = Pending(events[d.event].timestamp, cast(uint) i);
        auto heap = PendingHeap(initial);

        auto cursor = new size_t[endpoints.length];
        auto disabled = new bool[endpoints.length];

        while (heap.length != 0)
        {
            immutable p = heap.pop();
            auto d = &report.deliveries[p.delivery];
            immutable epIndex = d.endpoint;
            if (disabled[epIndex])
            {
                d.status = DeliveryStatus.disabled;
                continue;
            }
            const script = endpoints[epIndex].script;
            immutable at = cursor[epIndex] < script.length ? cursor[epIndex] : script.length - 1;
            cursor[epIndex]++;
            immutable response = script[at];

            d.attempts++;
            d.lastTime = p.time;
            report.attempts ~= AttemptRecord(p.delivery, d.attempts, response, p.time);

            final switch (outcomeOf(response))
            {
            case Outcome.success:
                d.status = DeliveryStatus.delivered;
                break;
            case Outcome.gone:
                d.status = DeliveryStatus.failed;
                disabled[epIndex] = true;
                break;
            case Outcome.timeout:
            case Outcome.failure:
                if (d.attempts == maxAttempts)
                    d.status = DeliveryStatus.failed;
                else
                    heap.push(Pending(p.time + retryDelays[d.attempts - 1], p.delivery));
                break;
            }
        }
        return report;
    }
}
