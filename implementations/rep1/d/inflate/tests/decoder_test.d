/// Unit tests for inflate.decoder.
module decoder_test;

import std.exception : assertThrown;

import inflate;

private ubyte[] hex(string s) @safe { return hexDecode(s); }

private void expectError(string h, InflateError want) @safe
{
    try
        decompress(hex(h));
    catch (InflateException e)
    {
        assert(e.error == want, describe(e.error));
        return;
    }
    assert(false, "stream should have been rejected: " ~ h);
}

@safe unittest
{
    // Examples from SPEC.md.
    assert(decompress(hex("0300")) == []);
    assert(decompress(hex("010100feff41")) == [0x41]);
    assert(decompress(hex("4b4c4a862000")) == hex("616263616263616263"));
}

@safe unittest
{
    // Stored blocks: empty, several, and nonzero discarded bits before LEN.
    assert(decompress(hex("010000ffff")) == []);
    assert(decompress(hex("000100feff41" ~ "010100feff42")) == [0x41, 0x42]);
    assert(decompress(hex("e10100feff41")) == [0x41]);
}

@safe unittest
{
    // Fixed block: 'a' followed by an overlapping copy of 299 bytes at distance 1.
    auto expected = new ubyte[300];
    expected[] = 'a';
    assert(decompress(hex("4b4c1c05c40200")) == expected);
}

@safe unittest
{
    // Dynamic-Huffman block produced by zlib (BTYPE = 2).
    enum text = "the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. pack my box with five dozen liquor jugs";
    assert(decompress(hex("ddcbc91180201044d1543a027302655360d811a377ca303c76fdd7cd2ae4eef60bb2d08cd074e3ec2155d050058db317cfc24166fbd6af7112ecc28264345db3d06e284e8f8af02e772afc35f505")) == cast(const(ubyte)[]) text);
}

@safe unittest
{
    expectError("", InflateError.truncated);
    expectError("00", InflateError.truncated);
    expectError("07", InflateError.invalidBlockType);
    expectError("010100feff", InflateError.truncated);   // stored data missing
    expectError("010100fe", InflateError.truncated);     // NLEN cut short
    expectError("010100ffff41", InflateError.storedLengthMismatch);
    expectError("030200", InflateError.distanceTooFar);
    expectError("0300" ~ "00", InflateError.trailingData);
    expectError("010100feff4100", InflateError.trailingData);
}

@safe unittest
{
    // Reusing an Inflater gives the same results.
    auto d = Inflater(0);
    assert(d.run(hex("010100feff41")) == [0x41]);
    assert(d.run(hex("4b4c4a862000")) == hex("616263616263616263"));
}

@safe unittest
{
    ubyte[] r;
    InflateError e;
    assert(tryDecompress(hex("0300"), r, e) && r.length == 0);
    assert(!tryDecompress(hex("07"), r, e) && e == InflateError.invalidBlockType);
}
