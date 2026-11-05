/// Unit tests for the delivery simulator and the command language.
module tests.simulator_test;

import webhooks;

private const(ubyte)[] bytes(string s)
{
    return asBytes(s);
}

private string simulate(string[] lines)
{
    string text = "simulate\n";
    foreach (l; lines)
        text ~= l ~ "\n";
    return processString(text);
}

private immutable secretA = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";

unittest
{
    immutable expected = "sim 5 3
attempt 1 msg_1 ep_a 1 1700000000 failure 500
attempt 2 msg_1 ep_b 1 1700000000 success 200
attempt 3 msg_1 ep_a 2 1700000005 timeout -
attempt 4 msg_2 ep_a 1 1700000100 success 200
attempt 5 msg_1 ep_a 3 1700000305 success 200
delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=
delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=
delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=
";
    assert(simulate([
        "endpoint ep_a " ~ secretA ~ " * 500,timeout,200",
        "endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200",
        "event msg_1 1700000000 user.created 7b7d",
        "event msg_2 1700000100 repo.pushed 7b7d",
        "end",
    ]) == expected);
}

unittest
{
    // A permanently failing endpoint: 8 attempts on the fixed schedule, then failed.
    auto out_ = simulate([
        "endpoint e c2VjcmV0 * 500",
        "event m 100 t -",
        "end",
    ]);
    foreach (t; ["100", "105", "405", "2205", "9405", "27405", "63405", "99405"])
        assert(contains(out_, " " ~ t ~ " failure 500\n"), t);
    assert(contains(out_, "sim 8 1\n"));
    assert(contains(out_, "delivery m e failed 8 99405 v1,"));
}

unittest
{
    // 410 disables the endpoint; the other delivery's retry then ends as `disabled`.
    auto out_ = simulate([
        "endpoint e c2VjcmV0 * 500,410",
        "event a 0 t -",
        "event b 1 t -",
        "end",
    ]);
    assert(contains(out_, "sim 2 2\n"));
    assert(contains(out_, "attempt 1 a e 1 0 failure 500\n"));
    assert(contains(out_, "attempt 2 b e 1 1 gone 410\n"));
    assert(contains(out_, "delivery a e disabled 1 0 v1,"));
    assert(contains(out_, "delivery b e failed 1 1 v1,"));
}

unittest
{
    // Delivery that never gets an attempt: `-` for the last time.
    auto out_ = simulate([
        "endpoint e c2VjcmV0 * 410",
        "event a 5 t -",
        "event b 5 t -",
        "end",
    ]);
    assert(contains(out_, "delivery b e disabled 0 - v1,"));
}

unittest
{
    // Events out of order are processed by time; filters match exact types only.
    auto out_ = simulate([
        "endpoint e c2VjcmV0 a.b,c 200",
        "event late 50 a.b -",
        "event early 10 c -",
        "event skipped 20 a -",
        "end",
    ]);
    assert(contains(out_, "sim 2 2\nattempt 1 early e 1 10 success 200\nattempt 2 late e 1 50 success 200\n"));
}

unittest
{
    // A block without events is fine.
    assert(simulate(["endpoint e c2VjcmV0 * 200", "end"]) == "sim 0 0\n");
}

unittest
{
    // Every malformed block collapses to one `error`, and parsing resumes after `end`.
    string[][] bad = [
        ["end"], // no endpoint
        ["endpoint e c2VjcmV0 * 200", "endpoint e c2VjcmV0 * 200", "end"], // duplicate id
        ["endpoint e c2VjcmV0 * 200", "event a 0 t -", "endpoint f c2VjcmV0 * 200", "end"],
        ["endpoint e c2VjcmV0 * 200", "event a 0 t -", "event a 0 t -", "end"],
        ["endpoint e c2VjcmV0 * 600", "end"],
        ["endpoint e c2VjcmV0 * 099", "end"],
        ["endpoint e c2VjcmV0 * Timeout", "end"],
        ["endpoint e c2VjcmV0 * 200,", "end"],
        ["endpoint e c2VjcmV0 *,a 200", "end"],
        ["endpoint e c2VjcmV0 a,,b 200", "end"],
        ["endpoint e x * 200", "end"], // invalid secret
        ["endpoint e c2VjcmV0 * 200 extra", "end"],
        ["endpoint e c2VjcmV0 * 200", "event a 007 t -", "end"],
        ["endpoint e c2VjcmV0 * 200", "event a 0 t ABC", "end"],
        ["endpoint e c2VjcmV0 * 200", "event a 0 t", "end"],
        ["endpoint e c2VjcmV0 * 200", "simulate", "end"],
        ["endpoint e c2VjcmV0 * 200", "frobnicate", "end"],
        ["endpoint e c2VjcmV0 * 200", "end extra", "sha256 -", "end"],
        ["endpoint  e c2VjcmV0 * 200", "end"],
    ];
    foreach (b; bad)
    {
        string text = "simulate\n";
        foreach (l; b)
            text ~= l ~ "\n";
        // Lines after the block's `end` are ordinary commands again.
        immutable res = processString(text ~ "sha256 -\n");
        assert(res == "error\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n", text);
    }
    // Missing `end` at EOF.
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\n") == "error\n");
    // `simulate now` is a plain error and opens no block.
    assert(processString("simulate now\nend\nendpoint x\nevent y\n") == "error\nerror\nerror\nerror\n");
}

unittest
{
    // Blank lines are ignored inside a block.
    assert(processString("simulate\n\n  \nendpoint e c2VjcmV0 * 200\n \nend\n") == "sim 0 0\n");
}

unittest
{
    // Limits: 64 endpoints ok, 65th rejected; event cap 20000.
    string eps;
    foreach (i; 0 .. 64)
        eps ~= "endpoint e" ~ itoa(i) ~ " c2VjcmV0 * 200\n";
    assert(processString("simulate\n" ~ eps ~ "end\n") == "sim 0 0\n");
    assert(processString("simulate\n" ~ eps ~ "endpoint x c2VjcmV0 * 200\nend\n") == "error\n");

    string evs;
    foreach (i; 0 .. 20_000)
        evs ~= "event v" ~ itoa(i) ~ " 0 t -\n";
    auto ok = processString("simulate\nendpoint e c2VjcmV0 * 200\n" ~ evs ~ "end\n");
    assert(ok.length > 5 && ok[0 .. 12] == "sim 20000 20");
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\n" ~ evs ~ "event over 0 t -\nend\n") == "error\n");
}

// --- command language ------------------------------------------------------

unittest
{
    immutable input = "sha256 -
sha256 616263
hmac - -
b64enc 666f6f
b64urlenc fbff
b64dec 5a6d3976
b64dec -
secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw
sign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 7b2274657374223a20323433323233323331347d
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265400 76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d 7b2274657374223a20323433323233323331347d
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265631 76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d 7b2274657374223a20323433323233323331347d
sha256 ABCD
sha256 abc
frobnicate 1
";
    immutable expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
Zm9v
-_8
666f6f
-
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
ok 0 0
fail timestamp-too-old
error
error
error
";
    assert(processString(input) == expected);
}

unittest
{
    // Input quirks: blank lines, missing final newline, extra/empty fields, tabs.
    assert(processString("\n   \nsha256 -") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(processString("sha256  -\n sha256 -\nsha256 - \nsha256\tabc\nsha256 - -\n") == "error\nerror\nerror\nerror\nerror\n");
    // "AA" (hex 4141) decodes to one zero byte; "A" (hex 41) has an impossible length.
    assert(processString("b64enc -\nb64urlenc -\nb64dec 41\nb64dec 4141\n") == "-\n-\nerror\n00\n");
}

unittest
{
    assert(processString("sign c2VjcmV0 - 0 -\n").length > 0);
    assert(processString("sign c2VjcmV0 - 007 -\n") == "error\n");
    assert(processString("sign c2VjcmV0 - 0\n") == "error\n");
    assert(processString("sign whsec_ a 0 -\n") == "error\n");
    assert(processString("secret whsec_\n") == "error\n");
    assert(processString("secret a,b\n") == "error\n");
    // verify: non-canonical timestamps are data, not syntax errors; `now` must be canonical
    assert(processString("verify c2VjcmV0 i 007 0 61 -\n") == "fail invalid-timestamp\n");
    assert(processString("verify c2VjcmV0 i 7 007 61 -\n") == "error\n");
    assert(processString("verify c2VjcmV0 i 7 0 - -\n") == "fail missing-signature\n");
}

private bool contains(string haystack, string needle)
{
    if (needle.length > haystack.length)
        return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return true;
    return false;
}

private string itoa(int n)
{
    OutBuffer o;
    o.putInt(n);
    return o.toString();
}
