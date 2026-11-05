module tests.date_test;

import mime.buffer;
import mime.date;

private string show(string raw)
{
    ParsedDate d;
    if (!parseDate(raw, d))
        return "invalid";
    ByteBuffer o;
    putUtc(o, d.epoch);
    o.put(' ');
    putOffset(o, d.offsetMinutes);
    o.put(' ');
    o.putInt(d.epoch);
    return o.toString();
}

unittest // examples from the specification
{
    assert(show("Sun, 29 Feb 2004 22:03:22 -0800") == "2004-03-01T06:03:22Z -0800 1078121002");
    assert(show("3 Jan 70 00:00:00 GMT") == "1970-01-03T00:00:00Z +0000 172800");
    assert(show("Tue, 1 Jan 2036 00:00:60 +0000") == "2036-01-01T00:01:00Z +0000 2082758460");
    assert(show("Mon, 3 Mar 1969 12:00 (GMT) -0500") == "1969-03-03T17:00:00Z -0500 -26204400");
    assert(show("Sun, 07 Mar 2004 15:21:26 -0000") == "2004-03-07T15:21:26Z +0000 1078672886");
    assert(show("1 Jan 2000 00:00:00 +2359") == "1999-12-31T00:01:00Z +2359 946598460");
    assert(show("not a date") == "invalid");
}

unittest // validity rules
{
    assert(show("30 Feb 2001 00:00:00") == "invalid");
    assert(show("29 Feb 1900 00:00:00") == "invalid");
    assert(show("29 Feb 2000 00:00:00") == "2000-02-29T00:00:00Z +0000 951782400");
    assert(show("32 Jan 2000 00:00:00") == "invalid");
    assert(show("1 Foo 2000 00:00:00") == "invalid");
    assert(show("1 Jan 2000 24:00:00") == "invalid");
    assert(show("1 Jan 2000 00:60:00") == "invalid");
    assert(show("1 Jan 2000 00:00:61") == "invalid");
    assert(show("1 Jan 2000") == "invalid");
    assert(show("1 Jan 0000 00:00") == "invalid");
}

unittest // zones, years and tokens
{
    assert(show("1 jan 2000 00:00 EST") == "2000-01-01T05:00:00Z -0500 946702800");
    assert(show("1 Jan 2000 00:00:00 +9999") == "1999-12-27T19:21:00Z +10039 946322460");
    assert(show("1 Jan 49 00:00:00 z") == "2049-01-01T00:00:00Z +0000 2493072000");
    assert(show("1 Jan 100 00:00:00") == "2000-01-01T00:00:00Z +0000 946684800");
    assert(show("1 Jan 2000 00:00:00 bogus extra") == "2000-01-01T00:00:00Z +0000 946684800");
    assert(show("(c) Sat,1 Jan 2000 00:00:00 PST") == "2000-01-01T08:00:00Z -0800 946713600");
}

unittest // calendar conversion round-trips, including before 1970
{
    foreach (days; [-800_000L, -719_468, -1, 0, 1, 11_016, 2_932_896])
    {
        long y;
        int m, d;
        civilFromDays(days, y, m, d);
        assert(daysFromCivil(y, m, d) == days);
    }
    assert(daysFromCivil(1970, 1, 1) == 0);
    assert(daysFromCivil(1969, 12, 31) == -1);
}
