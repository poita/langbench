/**
 * A deterministic webhook delivery simulator.
 *
 * A `Scenario` lists endpoints (each with signing secrets, an event-type
 * filter and a scripted sequence of responses) and events. `simulate`
 * creates one signed delivery per matching (event, endpoint) pair and runs
 * them through the fixed retry schedule with a priority queue ordered by
 * `(scheduled time, delivery number)`.
 */
module webhooks.simulator;

import webhooks.heap;
import webhooks.secret;
import webhooks.signature : signatureHeader;

/// Maximum number of attempts per delivery (the first plus seven retries).
enum size_t maxAttempts = 8;

/// Delay in seconds after attempt `n` (1-based) before attempt `n + 1`.
immutable long[7] retryDelays = [5, 300, 1800, 7200, 18000, 36000, 36000];

/// A scripted endpoint response: an HTTP status code, or a timeout.
struct Response
{
    /// 100..599, or 0 for a timeout.
    ushort code;

    /// A timeout response.
    static Response timeout() pure nothrow @safe @nogc
    {
        return Response(0);
    }

    /// `true` for a timeout.
    bool isTimeout() const pure nothrow @safe @nogc
    {
        return code == 0;
    }
}

/// A webhook receiver.
struct Endpoint
{
    string id;
    Secret[] secrets;
    /// If `true`, every event type matches and `filter` is ignored.
    bool matchAll;
    /// The event types delivered when `matchAll` is `false`.
    string[] filter;
    /// Responses, consumed one per attempt; the last one repeats forever.
    /// Must not be empty.
    Response[] script;

    /// Does this endpoint receive events of `type`?
    bool matches(scope const(char)[] type) const pure nothrow @safe @nogc
    {
        if (matchAll)
            return true;
        foreach (f; filter)
            if (f == type)
                return true;
        return false;
    }
}

/// An event to deliver.
struct Event
{
    string id;
    /// The enqueue time exactly as written (it goes into `webhook-timestamp`).
    string timestampText;
    /// The enqueue time, Unix seconds.
    long timestamp;
    string type;
    immutable(ubyte)[] payload;
}

/// Input of a simulation.
struct Scenario
{
    Endpoint[] endpoints;
    Event[] events;
}

/// Result of one attempt.
enum Outcome
{
    success,
    failure,
    timeout,
    gone,
}

/// Final state of a delivery.
enum DeliveryStatus
{
    pending,
    delivered,
    failed,
    disabled,
}

/// One recorded attempt.
struct Attempt
{
    uint delivery;
    /// 1-based attempt number within the delivery.
    ubyte number;
    long time;
    Outcome outcome;
    /// Status code, 0 for a timeout.
    ushort code;
}

/// One (event, endpoint) delivery.
struct Delivery
{
    /// Index into `Scenario.events`.
    uint event;
    /// Index into `Scenario.endpoints`.
    uint endpoint;
    /// The `webhook-signature` header, fixed at creation.
    string header;
    DeliveryStatus status;
    /// Attempts made (0..8).
    ubyte attempts;
    /// Time of the last attempt made; meaningful only if `attempts > 0`.
    long lastTime;
}

/// Output of `simulate`.
struct SimulationResult
{
    /// Attempts in processing order.
    Attempt[] attempts;
    /// Deliveries in creation order.
    Delivery[] deliveries;
}

private struct Pending
{
    long time;
    uint delivery;
}

private bool pendingLess(Pending a, Pending b) pure nothrow @safe @nogc
{
    return a.time < b.time || (a.time == b.time && a.delivery < b.delivery);
}

/**
 * Creates the deliveries of `scenario` in event order, then endpoint order,
 * signing each once.
 */
Delivery[] createDeliveries(const ref Scenario scenario) pure nothrow @safe
{
    Delivery[] deliveries;
    foreach (ei, ref event; scenario.events)
    {
        foreach (pi, ref endpoint; scenario.endpoints)
        {
            if (!endpoint.matches(event.type))
                continue;
            Delivery d;
            d.event = cast(uint) ei;
            d.endpoint = cast(uint) pi;
            d.header = signatureHeader(endpoint.secrets, cast(const(ubyte)[]) event.id,
                cast(const(ubyte)[]) event.timestampText, event.payload);
            d.status = DeliveryStatus.pending;
            deliveries ~= d;
        }
    }
    return deliveries;
}

/**
 * Runs the scenario to completion.
 *
 * Pending attempts live in a binary heap keyed by `(time, delivery number)`;
 * a delivery has at most one pending attempt, so the heap never holds more
 * than one entry per delivery and each step costs O(log D).
 */
SimulationResult simulate(const ref Scenario scenario) pure nothrow @safe
{
    SimulationResult result;
    result.deliveries = createDeliveries(scenario);

    auto cursors = new size_t[scenario.endpoints.length];
    auto disabled = new bool[scenario.endpoints.length];
    MinHeap!(Pending, pendingLess) queue;
    foreach (i, ref d; result.deliveries)
        queue.push(Pending(scenario.events[d.event].timestamp, cast(uint) i));

    while (!queue.empty)
    {
        immutable pending = queue.pop();
        auto d = &result.deliveries[pending.delivery];
        immutable ep = d.endpoint;

        if (disabled[ep])
        {
            d.status = DeliveryStatus.disabled;
            continue;
        }

        // Take the next scripted response; the last one repeats.
        auto script = scenario.endpoints[ep].script;
        immutable response = script[cursors[ep] < script.length ? cursors[ep] : script.length - 1];
        ++cursors[ep];

        Outcome outcome;
        if (response.isTimeout)
            outcome = Outcome.timeout;
        else if (response.code >= 200 && response.code <= 299)
            outcome = Outcome.success;
        else if (response.code == 410)
            outcome = Outcome.gone;
        else
            outcome = Outcome.failure;

        ++d.attempts;
        d.lastTime = pending.time;
        result.attempts ~= Attempt(pending.delivery, d.attempts, pending.time, outcome, response.code);

        final switch (outcome)
        {
        case Outcome.success:
            d.status = DeliveryStatus.delivered;
            break;
        case Outcome.gone:
            d.status = DeliveryStatus.failed;
            disabled[ep] = true;
            break;
        case Outcome.timeout:
        case Outcome.failure:
            if (d.attempts >= maxAttempts)
                d.status = DeliveryStatus.failed;
            else
                queue.push(Pending(pending.time + retryDelays[d.attempts - 1], pending.delivery));
            break;
        }
    }
    return result;
}

private string outcomeName(Outcome o) pure nothrow @safe @nogc
{
    final switch (o)
    {
    case Outcome.success:
        return "success";
    case Outcome.failure:
        return "failure";
    case Outcome.timeout:
        return "timeout";
    case Outcome.gone:
        return "gone";
    }
}

private string statusName(DeliveryStatus s) pure nothrow @safe @nogc
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

/// Appends the decimal text of `value` to `sink`.
void putInteger(Sink)(ref Sink sink, long value)
{
    char[20] buf = void;
    size_t pos = buf.length;
    immutable negative = value < 0;
    ulong v = negative ? -cast(ulong) value : cast(ulong) value;
    do
    {
        buf[--pos] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v != 0);
    if (negative)
        buf[--pos] = '-';
    sink.put(buf[pos .. $]);
}

/**
 * Writes the report of a simulation: a `sim <A> <D>` line, `A` attempt lines
 * and `D` delivery lines, each terminated by `\n`.
 */
void writeReport(Sink)(ref Sink sink, const ref Scenario scenario, const ref SimulationResult result)
{
    sink.put("sim ");
    putInteger(sink, result.attempts.length);
    sink.put(" ");
    putInteger(sink, result.deliveries.length);
    sink.put("\n");

    foreach (seq, ref a; result.attempts)
    {
        immutable d = result.deliveries[a.delivery];
        sink.put("attempt ");
        putInteger(sink, seq + 1);
        sink.put(" ");
        sink.put(scenario.events[d.event].id);
        sink.put(" ");
        sink.put(scenario.endpoints[d.endpoint].id);
        sink.put(" ");
        putInteger(sink, a.number);
        sink.put(" ");
        putInteger(sink, a.time);
        sink.put(" ");
        sink.put(outcomeName(a.outcome));
        sink.put(" ");
        if (a.outcome == Outcome.timeout)
            sink.put("-");
        else
            putInteger(sink, a.code);
        sink.put("\n");
    }

    foreach (ref d; result.deliveries)
    {
        sink.put("delivery ");
        sink.put(scenario.events[d.event].id);
        sink.put(" ");
        sink.put(scenario.endpoints[d.endpoint].id);
        sink.put(" ");
        sink.put(statusName(d.status));
        sink.put(" ");
        putInteger(sink, d.attempts);
        sink.put(" ");
        if (d.attempts == 0)
            sink.put("-");
        else
            putInteger(sink, d.lastTime);
        sink.put(" ");
        sink.put(d.header);
        sink.put("\n");
    }
}

version (unittest)
{
    import std.array : appender;

    private Endpoint makeEndpoint(string id, string secret, string[] filter, ushort[] codes) @safe
    {
        Endpoint e;
        e.id = id;
        Secret s;
        assert(Secret.parse(secret, s));
        e.secrets = [s];
        e.matchAll = filter.length == 0;
        e.filter = filter;
        foreach (c; codes)
            e.script ~= Response(c);
        return e;
    }
}

/// The spec's worked example (headers omitted from the comparison).
@safe unittest
{
    Scenario sc;
    sc.endpoints = [
        makeEndpoint("ep_a", "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", [], [500, 0, 200]),
        makeEndpoint("ep_b", "whsec_c2VjcmV0", ["user.created"], [200]),
    ];
    sc.events = [
        Event("msg_1", "1700000000", 1_700_000_000, "user.created", [0x7b, 0x7d]),
        Event("msg_2", "1700000100", 1_700_000_100, "repo.pushed", [0x7b, 0x7d]),
    ];
    auto r = simulate(sc);
    auto sink = appender!string();
    writeReport(sink, sc, r);
    import std.string : splitLines;

    auto lines = sink[].splitLines();
    assert(lines[0 .. 6] == [
        "sim 5 3",
        "attempt 1 msg_1 ep_a 1 1700000000 failure 500",
        "attempt 2 msg_1 ep_b 1 1700000000 success 200",
        "attempt 3 msg_1 ep_a 2 1700000005 timeout -",
        "attempt 4 msg_2 ep_a 1 1700000100 success 200",
        "attempt 5 msg_1 ep_a 3 1700000305 success 200",
    ]);
    assert(lines[6] == "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=");
}

/// A 410 disables the endpoint; later attempts are recorded as `disabled`.
@safe unittest
{
    Scenario sc;
    sc.endpoints = [makeEndpoint("e", "c2VjcmV0", [], [500, 410, 200])];
    sc.events = [
        Event("a", "0", 0, "t", []),
        Event("b", "1", 1, "t", []),
    ];
    auto r = simulate(sc);
    // a@0 -> 500, b@1 -> 410 (gone, endpoint disabled), a@5 -> disabled.
    assert(r.attempts.length == 2);
    assert(r.attempts[1].outcome == Outcome.gone);
    assert(r.deliveries[0].status == DeliveryStatus.disabled);
    assert(r.deliveries[0].attempts == 1 && r.deliveries[0].lastTime == 0);
    assert(r.deliveries[1].status == DeliveryStatus.failed);
}

/// Eight failing attempts land on the documented schedule, then give up.
@safe unittest
{
    Scenario sc;
    sc.endpoints = [makeEndpoint("e", "c2VjcmV0", [], [503])];
    sc.events = [Event("a", "100", 100, "t", [])];
    auto r = simulate(sc);
    long[] times;
    foreach (a; r.attempts)
        times ~= a.time;
    assert(times == [100, 105, 405, 2205, 9405, 27405, 63405, 99405]);
    assert(r.deliveries[0].status == DeliveryStatus.failed && r.deliveries[0].attempts == 8);
}

/// Events need not be declared in timestamp order.
@safe unittest
{
    Scenario sc;
    sc.endpoints = [makeEndpoint("e", "c2VjcmV0", [], [200])];
    sc.events = [Event("late", "50", 50, "t", []), Event("early", "-5", -5, "t", [])];
    auto r = simulate(sc);
    assert(r.attempts[0].delivery == 1 && r.attempts[1].delivery == 0);
}
