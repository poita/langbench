/// Keeps the documentation examples (module docs, README) honest.
module tests.test_docs;

import bigint;

unittest
{
    auto a = BigInt("123456789012345678901234567890");
    auto b = BigInt("-987654321");
    assert((a + b).toString() == "123456789012345678900246913569");
    assert((a / b).toString() == "-124999998873437499901");
    assert(BigInt(2) ^^ 100 == BigInt("1267650600228229401496703205376"));

    BigInt q, r;
    divMod(BigInt("-7"), BigInt("2"), q, r);
    assert(q == BigInt(-3) && r == BigInt(-1));
}
