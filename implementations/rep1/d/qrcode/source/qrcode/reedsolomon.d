/// Reed-Solomon error correction over GF(2^8) with polynomial 0x11D.
module qrcode.reedsolomon;

/// Multiplies two field elements (carry-less product reduced modulo 0x11D).
ubyte gfMultiply(ubyte x, ubyte y) @safe pure nothrow @nogc
{
    uint z = 0;
    foreach_reverse (i; 0 .. 8)
    {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((y >> i) & 1) * x;
    }
    return cast(ubyte) z;
}

/**
 * Returns the coefficients of the degree-`degree` generator polynomial
 * `prod (x - 2^i)`, highest degree first, omitting the leading 1.
 */
ubyte[] generatorPolynomial(int degree) @safe pure nothrow
in (degree >= 1 && degree <= 255)
{
    auto result = new ubyte[degree];
    result[$ - 1] = 1;
    ubyte root = 1;
    foreach (_; 0 .. degree)
    {
        foreach (j; 0 .. degree)
        {
            result[j] = gfMultiply(result[j], root);
            if (j + 1 < degree)
                result[j] ^= result[j + 1];
        }
        root = gfMultiply(root, 2);
    }
    return result;
}

/**
 * Computes the `generator.length` ECC codewords for `data`: the remainder of
 * `data(x) * x^E` divided by the generator polynomial, highest degree first.
 */
ubyte[] remainder(const(ubyte)[] data, const(ubyte)[] generator) @safe pure nothrow
{
    auto result = new ubyte[generator.length];
    foreach (b; data)
    {
        const factor = cast(ubyte)(b ^ result[0]);
        foreach (i; 0 .. result.length - 1)
            result[i] = result[i + 1];
        result[$ - 1] = 0;
        foreach (i, c; generator)
            result[i] ^= gfMultiply(c, factor);
    }
    return result;
}

/// Convenience: ECC codewords of `data` using a freshly built generator of degree `eccLen`.
ubyte[] computeEcc(const(ubyte)[] data, int eccLen) @safe pure nothrow
{
    return remainder(data, generatorPolynomial(eccLen));
}

@safe pure nothrow @nogc unittest
{
    assert(gfMultiply(2, 0x80) == 0x1D); // 2^8 = 0x1D
    assert(gfMultiply(0, 77) == 0 && gfMultiply(1, 77) == 77);
    assert(gfMultiply(0x53, 0xCA) == gfMultiply(0xCA, 0x53));
}

@safe pure unittest
{
    // Degree 7 generator from the QR standard: coefficients (alpha exponents) 21 102 238 149 146 229 87 0
    assert(generatorPolynomial(2) == [3, 2]);
    assert(generatorPolynomial(7) == [127, 122, 154, 164, 11, 68, 117]);
}

@safe pure unittest
{
    // Worked example 1 of the specification (version 1-M "HELLO WORLD").
    ubyte[] data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    assert(computeEcc(data, 10) == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
}
