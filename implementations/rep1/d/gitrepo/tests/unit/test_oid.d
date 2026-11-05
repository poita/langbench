/// Unit tests for gitrepo.oid and gitrepo.quote.
module unit.test_oid;

import std.exception : assertThrown;

import gitrepo.errors;
import gitrepo.oid;
import gitrepo.quote;

unittest
{
    auto id = ObjectId.fromHex("b7814cae2e925fe74c6cd5816462fff515ccb256");
    assert(id.bytes[0] == 0xb7 && id.bytes[19] == 0x56);
    assert(id.toString() == "b7814cae2e925fe74c6cd5816462fff515ccb256");
    assert(ObjectId.fromHex("B7814CAE2E925FE74C6CD5816462FFF515CCB256") == id);
    assertThrown!GitError(ObjectId.fromHex("b78"));
    assertThrown!GitError(ObjectId.fromHex("zz814cae2e925fe74c6cd5816462fff515ccb256"));
    ObjectId o;
    assert(!ObjectId.tryParse("B7814CAE2E925FE74C6CD5816462FFF515CCB256", o));
}

unittest
{
    auto a = ObjectId.fromHex("0000000000000000000000000000000000000001");
    auto b = ObjectId.fromHex("0000000000000000000000000000000000000002");
    assert(a < b && b > a && a != b);
    int[ObjectId] m;
    m[a] = 1;
    m[b] = 2;
    assert(m[a] == 1 && m[b] == 2);
}

unittest
{
    assert(quotePath("plain.txt") == "plain.txt");
    assert(quotePath("café.txt") == `"caf\303\251.txt"`);
    assert(quotePath("quote\"and\\slash.txt") == `"quote\"and\\slash.txt"`);
    assert(quotePath("tab\there") == `"tab\there"`);
    assert(quotePath("a\x01b\x7f") == `"a\001b\177"`);
    assert(quotePath("") == "");
}
