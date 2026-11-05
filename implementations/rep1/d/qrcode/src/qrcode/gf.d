/**
 * Arithmetic in GF(2^8) (primitive polynomial 0x11D) and Reed-Solomon
 * error-correction coding.
 */
module qrcode.gf;

private struct Tables
{
    ubyte[512] exp; // doubled so that exp[log a + log b] needs no reduction
    ubyte[256] log;
}

private Tables buildTables() @safe pure nothrow @nogc
{
    Tables t;
    int x = 1;
    foreach (i; 0 .. 255)
    {
        t.exp[i] = cast(ubyte) x;
        t.log[x] = cast(ubyte) i;
        x <<= 1;
        if (x & 0x100)
            x ^= 0x11D;
    }
    foreach (i; 255 .. 512)
        t.exp[i] = t.exp[i - 255];
    return t;
}

private static immutable Tables tables = buildTables();

/// Multiply two field elements using log/antilog tables.
ubyte gfMul(ubyte a, ubyte b) @safe pure nothrow @nogc
{
    if (a == 0 || b == 0)
        return 0;
    return tables.exp[tables.log[a] + tables.log[b]];
}

/// `2^i` in the field.
ubyte gfPow2(int i) @safe pure nothrow @nogc
in (i >= 0)
{
    return tables.exp[i % 255];
}

/**
 * Coefficients of the monic generator polynomial of the given degree,
 * `prod_{i<degree} (x - 2^i)`, highest power first, omitting the leading 1.
 */
ubyte[] rsGenerator(int degree) @safe pure nothrow
in (degree >= 1 && degree <= 255)
{
    auto result = new ubyte[degree];
    result[$ - 1] = 1;
    ubyte root = 1;
    foreach (i; 0 .. degree)
    {
        foreach (j; 0 .. degree)
        {
            result[j] = gfMul(result[j], root);
            if (j + 1 < degree)
                result[j] ^= result[j + 1];
        }
        root = gfMul(root, 2);
    }
    return result;
}

/**
 * Compute the Reed-Solomon remainder of `data(x) * x^degree` modulo the
 * generator `gen` (as returned by $(LREF rsGenerator)), writing
 * `gen.length` ECC codewords into `ecc`.
 */
void rsRemainder(const(ubyte)[] data, const(ubyte)[] gen, ubyte[] ecc) @safe pure nothrow @nogc
in (ecc.length == gen.length)
{
    const n = gen.length;
    ecc[] = 0;
    foreach (b; data)
    {
        const factor = cast(ubyte)(b ^ ecc[0]);
        foreach (j; 0 .. n - 1)
            ecc[j] = ecc[j + 1];
        ecc[n - 1] = 0;
        if (factor != 0)
        {
            const lf = tables.log[factor];
            foreach (j; 0 .. n)
            {
                const g = gen[j];
                if (g != 0)
                    ecc[j] ^= tables.exp[tables.log[g] + lf];
            }
        }
    }
}
