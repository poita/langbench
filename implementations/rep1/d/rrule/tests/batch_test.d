/// Unit tests for `rrule.batch` (the engine of the command-line tool).
module batch_test;

import rrule.batch;
import rrule.errors;

import std.exception : assertThrown;

private string process(string input, size_t threshold = 1 << 22)
{
    OutputBuffer buf;
    string result;
    processInput(input, buf, (const(ubyte)[] chunk) { result ~= cast(const(char)[]) chunk; }, threshold);
    return result;
}

unittest
{
    auto out_ = process("19970902T090000 FREQ=DAILY;COUNT=3 10\n"
        ~ "20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10\n"
        ~ "20240229T120000 FREQ=YEARLY;COUNT=3 10");
    assert(out_ == "19970902T090000 19970903T090000 19970904T090000\n\n"
        ~ "20240229T120000 20280229T120000 20320229T120000\n");
}

unittest // small flush threshold produces identical output
{
    string input;
    foreach (i; 0 .. 50)
        input ~= "20240101T000000 FREQ=DAILY 5\n";
    assert(process(input, 1) == process(input));
}

unittest // empty input and malformed lines
{
    assert(process("") == "");
    assertThrown!RRuleException(process("garbage\n"));
    assertThrown!RRuleException(process("20240101T000000 FREQ=DAILY x\n"));
    assertThrown!RRuleException(process("20240101T000000 FREQ=NEVER 3\n"));
}
