module test_semver;

import std.exception : assertThrown;
import depresolve.semver;

unittest // parse and print
{
    assert(parseVersion("1.2.3") == Version(1, 2, 3));
    assert(parseVersion("0.0.0") == Version(0, 0, 0));
    assert(parseVersion("1000000.1000000.1000000") == Version(1_000_000, 1_000_000, 1_000_000));
    assert(Version(10, 0, 7).toString == "10.0.7");
}

unittest // malformed versions
{
    foreach (bad; ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "a.b.c",
                   "1.2.3-beta", "1.2.3+x", " 1.2.3", "1.2.3 ", "1..3", "-1.2.3"])
        assertThrown!ParseException(parseVersion(bad), bad);
}

unittest // numeric ordering
{
    assert(Version(1, 10, 0) > Version(1, 9, 0));
    assert(Version(2, 0, 0) > Version(1, 999_999, 999_999));
    assert(Version(1, 2, 3) == Version(1, 2, 3));
    assert(Version(0, 0, 1) < Version(0, 1, 0));
    assert(Version(1, 10, 0).key > Version(1, 9, 0).key);
}

unittest // key round trip and headroom for exclusive bounds
{
    auto v = Version(1_000_000, 999_999, 12_345);
    assert(Version.fromKey(v.key) == v);
    assert(packKey(1_000_001, 0, 0) > Version(1_000_000, 1_000_000, 1_000_000).key);
    assert(packKey(0, 1_000_001, 0) > packKey(0, 1_000_000, 1_000_000));
    assert(packKey(0, 0, 1_000_001) > packKey(0, 0, 1_000_000));
    assert(packKey(0, 1_000_001, 0) < packKey(1, 0, 0));
}
