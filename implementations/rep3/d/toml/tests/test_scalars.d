module tests.test_scalars;

import tests.helpers;
import toml;

unittest // integers
{
    assert(decode("a = 42") == `{"a":` ~ scalar("integer", "42") ~ `}`);
    assert(decode("a = -17") == `{"a":` ~ scalar("integer", "-17") ~ `}`);
    assert(decode("a = +0") == `{"a":` ~ scalar("integer", "0") ~ `}`);
    assert(decode("a = 1_000") == `{"a":` ~ scalar("integer", "1000") ~ `}`);
    assert(decode("a = 0xDEAD_beef") == `{"a":` ~ scalar("integer", "3735928559") ~ `}`);
    assert(decode("a = 0o755") == `{"a":` ~ scalar("integer", "493") ~ `}`);
    assert(decode("a = 0b1101") == `{"a":` ~ scalar("integer", "13") ~ `}`);
    assert(decode("a = 0x00ff") == `{"a":` ~ scalar("integer", "255") ~ `}`);
    assert(decode("a = 9223372036854775807") == `{"a":` ~ scalar("integer", "9223372036854775807") ~ `}`);
    assert(decode("a = -9223372036854775808") == `{"a":` ~ scalar("integer", "-9223372036854775808") ~ `}`);
}

unittest // invalid integers
{
    foreach (bad; ["a = 01", "a = +01", "a = 1__0", "a = _1", "a = 1_", "a = 0X1", "a = -0x1",
                   "a = 0x", "a = 0b2", "a = 0o8", "a = 9223372036854775808",
                   "a = -9223372036854775809", "a = 0xFFFFFFFFFFFFFFFF", "a = 0_1"])
        assert(rejects(bad), bad);
}

unittest // floats
{
    assert(decode("a = 1.0") == `{"a":` ~ scalar("float", "1.0000000000000000e+00") ~ `}`);
    assert(decode("a = 3.1415") == `{"a":` ~ scalar("float", "3.1415000000000002e+00") ~ `}`);
    assert(decode("a = -0.0") == `{"a":` ~ scalar("float", "-0.0000000000000000e+00") ~ `}`);
    assert(decode("a = 0e0") == `{"a":` ~ scalar("float", "0.0000000000000000e+00") ~ `}`);
    assert(decode("a = 6.626e-34") == `{"a":` ~ scalar("float", "6.6259999999999998e-34") ~ `}`);
    assert(decode("a = 5e-324") == `{"a":` ~ scalar("float", "4.9406564584124654e-324") ~ `}`);
    assert(decode("a = 1e308") == `{"a":` ~ scalar("float", "1.0000000000000000e+308") ~ `}`);
    assert(decode("a = 1e999") == `{"a":` ~ scalar("float", "inf") ~ `}`);
    assert(decode("a = -1e999") == `{"a":` ~ scalar("float", "-inf") ~ `}`);
    assert(decode("a = 1e-999") == `{"a":` ~ scalar("float", "0.0000000000000000e+00") ~ `}`);
    assert(decode("a = 1_0.2_5e+0_1") == `{"a":` ~ scalar("float", "1.0250000000000000e+02") ~ `}`);
    assert(decode("a = 0e00") == `{"a":` ~ scalar("float", "0.0000000000000000e+00") ~ `}`);
    assert(decode("a = inf") == `{"a":` ~ scalar("float", "inf") ~ `}`);
    assert(decode("a = -inf") == `{"a":` ~ scalar("float", "-inf") ~ `}`);
    assert(decode("a = -nan") == `{"a":` ~ scalar("float", "nan") ~ `}`);
    assert(decode("a = +nan") == `{"a":` ~ scalar("float", "nan") ~ `}`);
}

unittest // invalid floats
{
    foreach (bad; ["a = .5", "a = 5.", "a = 1.e2", "a = 1e", "a = 01.5", "a = 1._5", "a = 1e_5",
                   "a = Inf", "a = NaN", "a = 1.5.5", "a = 1.0_"])
        assert(rejects(bad), bad);
}

unittest // booleans
{
    assert(decode("a = true\nb = false") ==
        `{"a":` ~ scalar("bool", "true") ~ `,"b":` ~ scalar("bool", "false") ~ `}`);
    assert(rejects("a = True"));
    assert(rejects("a = tru"));
}

unittest // date-times
{
    assert(decode("a = 1979-05-27") == `{"a":` ~ scalar("date-local", "1979-05-27") ~ `}`);
    assert(decode("a = 07:32:00") == `{"a":` ~ scalar("time-local", "07:32:00") ~ `}`);
    assert(decode("a = 07:32:00.500") == `{"a":` ~ scalar("time-local", "07:32:00.5") ~ `}`);
    assert(decode("a = 07:32:00.000") == `{"a":` ~ scalar("time-local", "07:32:00") ~ `}`);
    assert(decode("a = 1979-05-27T07:32:00") == `{"a":` ~ scalar("datetime-local", "1979-05-27T07:32:00") ~ `}`);
    assert(decode("a = 1979-05-27t07:32:00") == `{"a":` ~ scalar("datetime-local", "1979-05-27T07:32:00") ~ `}`);
    assert(decode("a = 1979-05-27 07:32:00") == `{"a":` ~ scalar("datetime-local", "1979-05-27T07:32:00") ~ `}`);
    assert(decode("a = 1987-07-05 17:45:00z") == `{"a":` ~ scalar("datetime", "1987-07-05T17:45:00Z") ~ `}`);
    assert(decode("a = 1987-07-05T17:45:56.600+08:00") ==
        `{"a":` ~ scalar("datetime", "1987-07-05T17:45:56.6+08:00") ~ `}`);
    assert(decode("a = 1979-05-27t07:32:00-00:00") == `{"a":` ~ scalar("datetime", "1979-05-27T07:32:00Z") ~ `}`);
    assert(decode("a = 1979-05-27T07:32:00+00:00") == `{"a":` ~ scalar("datetime", "1979-05-27T07:32:00Z") ~ `}`);
    assert(decode("a = 1979-05-27 # comment") == `{"a":` ~ scalar("date-local", "1979-05-27") ~ `}`);
    assert(decode("a = 2024-02-29") == `{"a":` ~ scalar("date-local", "2024-02-29") ~ `}`);
}

unittest // invalid date-times
{
    foreach (bad; ["a = 2023-02-29", "a = 1900-02-29", "a = 1979-13-01", "a = 1979-00-10", "a = 1979-05-32",
                   "a = 0000-01-01", "a = 1979-5-27", "a = 07:32", "a = 24:00:00", "a = 07:60:00",
                   "a = 07:32:60", "a = 1979-05-27T07:32:00+24:00", "a = 1979-05-27T07:32:00+01:60",
                   "a = 1979-05-27T", "a = 07:32:00.", "a = 1979-05-27 07:32",
                   "a = \u0661\u0669\u0667\u0669-05-27"])
        assert(rejects(bad), bad);
}
