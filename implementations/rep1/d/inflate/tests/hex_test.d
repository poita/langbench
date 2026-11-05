/// Unit tests for inflate.hex.
module hex_test;

import std.exception : assertThrown;

import inflate.hex;

@safe unittest
{
    assert(hexDecode("") == []);
    assert(hexDecode("00ff10Ab") == [0x00, 0xff, 0x10, 0xab]);
}

@safe unittest
{
    assertThrown!HexException(hexDecode("abc"));
    assertThrown!HexException(hexDecode("zz"));
    assertThrown!HexException(hexDecode("0g"));
}

@safe unittest
{
    assert(hexEncode([]) == "");
    assert(hexEncode([0x00, 0xff, 0x1a], "\n") == "00ff1a\n");
    foreach (i; 0 .. 256)
    {
        immutable ubyte[1] one = [cast(ubyte) i];
        assert(hexDecode(hexEncode(one)) == one[]);
    }
}
