/// Unit tests for the simulator and the command protocol.
module tests.simulation;

import webhooks.commands;
import webhooks.outbuf;
import webhooks.simulator;

private const(ubyte)[] bytes(string s) @trusted pure nothrow
{
    return cast(const(ubyte)[]) s;
}

private string run(string input) @trusted
{
    OutBuf o;
    processInput(bytes(input), o);
    return cast(string) o.data.idup;
}

unittest // the SPEC simulate example
{
    enum input = "simulate\n"
        ~ "endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200\n"
        ~ "endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200\n"
        ~ "event msg_1 1700000000 user.created 7b7d\n"
        ~ "event msg_2 1700000100 repo.pushed 7b7d\n"
        ~ "end\n";
    enum expected = "sim 5 3\n"
        ~ "attempt 1 msg_1 ep_a 1 1700000000 failure 500\n"
        ~ "attempt 2 msg_1 ep_b 1 1700000000 success 200\n"
        ~ "attempt 3 msg_1 ep_a 2 1700000005 timeout -\n"
        ~ "attempt 4 msg_2 ep_a 1 1700000100 success 200\n"
        ~ "attempt 5 msg_1 ep_a 3 1700000305 success 200\n"
        ~ "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=\n"
        ~ "delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=\n"
        ~ "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=\n";
    assert(run(input) == expected);
}

unittest // retry schedule: eight attempts at the fixed offsets, then failed
{
    auto out_ = run("simulate\nendpoint e AAAA * 500\nevent v 100 t -\nend\n");
    immutable offsets = [0, 5, 305, 2105, 9305, 27305, 63305, 99305];
    foreach (i, off; offsets)
    {
        import std.conv : to;
        assert(contains(out_, "attempt " ~ to!string(i + 1) ~ " v e " ~ to!string(i + 1)
                ~ " " ~ to!string(100 + off) ~ " failure 500\n"));
    }
    assert(contains(out_, "delivery v e failed 8 99405 "));
}

private bool contains(string haystack, string needle) @safe pure nothrow @nogc
{
    if (needle.length > haystack.length)
        return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return true;
    return false;
}

unittest // 410 disables the endpoint for later deliveries
{
    auto out_ = run("simulate\nendpoint e AAAA * 410,200\n"
            ~ "event a 0 t -\nevent b 0 t -\nevent c 10 t -\nend\n");
    assert(contains(out_, "attempt 1 a e 1 0 gone 410\n"));
    assert(contains(out_, "sim 1 3\n"));
    assert(contains(out_, "delivery a e failed 1 0 "));
    assert(contains(out_, "delivery b e disabled 0 - "));
    assert(contains(out_, "delivery c e disabled 0 - "));
}

unittest // a retrying delivery becomes disabled when another delivery gets 410
{
    auto out_ = run("simulate\nendpoint e AAAA * 500,410\n"
            ~ "event a 0 t -\nevent b 1 t -\nend\n");
    // a: 500 at 0; b: 410 at 1 (disables); a's retry at 5 -> disabled
    assert(contains(out_, "delivery a e disabled 1 0 "));
    assert(contains(out_, "delivery b e failed 1 1 "));
}

unittest // filters and ordering by timestamp
{
    auto out_ = run("simulate\nendpoint x AAAA a,b 200\nendpoint y AAAA * 200\n"
            ~ "event late 50 b -\nevent early 10 c -\nend\n");
    assert(contains(out_, "sim 3 3\n"));
    assert(contains(out_, "attempt 1 early y 1 10 success 200\n"));
    assert(contains(out_, "attempt 2 late x 1 50 success 200\n"));
}

unittest // Simulation API used directly
{
    import webhooks.hmac : HmacKey;

    Simulation sim;
    Endpoint ep;
    ep.id = bytes("ep");
    ep.keys = [HmacKey(bytes("k"))];
    ep.wildcard = true;
    ep.script = [timeoutResponse, 200];
    sim.endpoints = [ep];
    Event ev;
    ev.id = bytes("ev");
    ev.timestampText = bytes("7");
    ev.timestamp = 7;
    ev.type = bytes("x");
    sim.events = [ev];
    auto report = sim.run();
    assert(report.attempts.length == 2);
    assert(report.attempts[0].time == 7 && report.attempts[1].time == 12);
    assert(report.deliveries[0].status == DeliveryStatus.delivered);
}

unittest // malformed blocks consume lines up to `end` and print one error
{
    assert(run("simulate\nendpoint e AAAA * 200\nevent a 0 t -\nevent a 0 t -\nend\nsha256 -\n")
        == "error\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(run("simulate\nend\n") == "error\n"); // no endpoints
    assert(run("simulate\nendpoint e AAAA * 200\n") == "error\n"); // no end
    assert(run("simulate\nendpoint e AAAA * 200\nevent a 0 t -\nendpoint f AAAA * 200\nend\n") == "error\n");
    assert(run("simulate now\nend\n") == "error\nerror\n");
    assert(run("simulate\nendpoint e AAAA * 200\nsimulate\nend\n") == "error\n");
    assert(run("simulate\nendpoint e AAAA * 0200\nend\n") == "error\n");
    assert(run("simulate\nendpoint e AAAA * 200\nend\n") == "sim 0 0\n");
}

unittest // basic commands, blank lines, and error lines
{
    assert(run("sha256 616263\n\n   \nsha256 ABCD\nsha256 abc\nnope\n sha256 -\nsha256  -\n")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\nerror\nerror\nerror\nerror\nerror\n");
    assert(run("b64enc -\nb64urlenc fbff\nb64dec 5a6d3976\nb64dec -\nb64dec 41\n")
        == "-\n-_8\n666f6f\n-\nerror\n");
    assert(run("sha256 -") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(run("secret whsec_\nsecret a,b\n") == "error\nerror\n");
    assert(run("sign AAAA id 01 -\nsign AAAA id 1 -\n").length > 6);
}

unittest // verify command output
{
    enum p = "7b2274657374223a20323433323233323331347d";
    enum h = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d";
    enum pre = "verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek ";
    assert(run(pre ~ "1614265330 1614265400 " ~ h ~ " " ~ p ~ "\n") == "ok 0 0\n");
    assert(run(pre ~ "1614265330 1614265631 " ~ h ~ " " ~ p ~ "\n") == "fail timestamp-too-old\n");
    assert(run(pre ~ "1614265330 1614265400 - " ~ p ~ "\n") == "fail missing-signature\n");
    assert(run(pre ~ "01 1614265400 " ~ h ~ " " ~ p ~ "\n") == "fail invalid-timestamp\n");
    assert(run(pre ~ "1614265330 01 " ~ h ~ " " ~ p ~ "\n") == "error\n");
}
