module tests.test_ops;

import jq;

private Value J(string s) { return parseJson(s); }
private string S(Value v) { return toJson(v); }

unittest // arithmetic
{
    assert(S(opAdd(J(`null`), J(`1`))) == `1`);
    assert(S(opAdd(J(`[1]`), J(`[2]`))) == `[1,2]`);
    assert(S(opAdd(J(`{"z":1,"a":2}`), J(`{"m":3,"z":9}`))) == `{"z":9,"a":2,"m":3}`);
    assert(opAdd(J(`1`), J(`"a"`)).isError);
    assert(S(opSub(J(`[1,2,3,2]`), J(`[2]`))) == `[1,3]`);
    assert(S(opMul(J(`"ab"`), J(`3`))) == `"ababab"`);
    assert(S(opMul(J(`"ab"`), J(`0`))) == `""`);
    assert(S(opMul(J(`"ab"`), J(`-1`))) == `null`);
    assert(S(opMul(J(`{"a":{"x":1}}`), J(`{"a":{"y":2}}`))) == `{"a":{"x":1,"y":2}}`);
    assert(S(opDiv(J(`"a,b,,c"`), J(`","`))) == `["a","b","","c"]`);
    assert(S(opDiv(J(`""`), J(`","`))) == `[]`);
    assert(S(opDiv(J(`"abc"`), J(`""`))) == `["a","b","c"]`);
    assert(opDiv(J(`1`), J(`0`)).isError);
    assert(S(opMod(J(`-7`), J(`3`))) == `-1`);
    assert(S(opMod(J(`7`), J(`-3`))) == `1`);
    assert(S(opMod(J(`5.5`), J(`2`))) == `1`);
    assert(opMod(J(`5`), J(`0.5`)).isError);
}

unittest // indexing and slicing
{
    assert(S(indexValue(J(`[1,2,3]`), J(`-1`))) == `3`);
    assert(S(indexValue(J(`[1,2,3]`), J(`5`))) == `null`);
    assert(S(indexValue(J(`null`), J(`"a"`))) == `null`);
    assert(indexValue(J(`null`), J(`null`)).isError);
    assert(indexValue(J(`[1]`), J(`"a"`)).isError);
    assert(S(sliceValue(J(`[1,2,3,4]`), J(`1`), J(`-1`))) == `[2,3]`);
    assert(S(sliceValue(J(`"héllo"`), J(`1`), J(`3`))) == `"él"`);
    assert(S(sliceValue(J(`[1,2]`), J(`5`), J(`null`))) == `[]`);
    assert(S(sliceValue(J(`[1,2,3]`), J(`2`), J(`1`))) == `[]`);
}

unittest // builtins
{
    assert(S(opLength(J(`"héllo"`))) == `5`);
    assert(S(opLength(J(`-3`))) == `3`);
    assert(S(opLength(J(`null`))) == `0`);
    assert(opLength(J(`true`)).isError);
    assert(S(opKeys(J(`{"b":1,"a":2,"é":3}`))) == `["a","b","é"]`);
    assert(S(opKeys(J(`[7,8]`))) == `[0,1]`);
    assert(S(opHas(J(`[1,2]`), J(`1.5`))) == `true`);
    assert(S(opHas(J(`[1,2]`), J(`-1`))) == `false`);
    assert(S(opHas(J(`null`), J(`"a"`))) == `false`);
    assert(opHas(J(`{}`), J(`1`)).isError);
    assert(S(opType(J(`true`))) == `"boolean"`);
    assert(S(opToString(J(`[1,{"a":"x"}]`))) == `"[1,{\"a\":\"x\"}]"`);
    assert(S(opToNumber(J(`"-2.5"`))) == `-2.5`);
    assert(opToNumber(J(`"abc"`)).isError);
    assert(opToNumber(J(`""`)).isError);
}

unittest // sort, unique, min, max
{
    assert(S(opSort(J(`[3,"a",null,[1],{"a":1},true,false,1]`))) == `[null,false,true,1,3,"a",[1],{"a":1}]`);
    assert(S(opUnique(J(`[2,1,2,1,3]`))) == `[1,2,3]`);
    assert(S(opMinMax(J(`[3,1,2]`), false)) == `1`);
    assert(S(opMinMax(J(`[]`), true)) == `null`);
    // ties: min keeps the first, max the last
    auto arr = J(`[{"a":1,"b":2},{"b":2,"a":1}]`);
    assert(S(opMinMax(arr, false)) == `{"a":1,"b":2}`);
    assert(S(opMinMax(arr, true)) == `{"b":2,"a":1}`);
    assert(S(opReverse(J(`null`))) == `[]`);
    assert(opReverse(J(`"abc"`)).isError);
}

unittest // add
{
    assert(S(opAddAll(J(`[]`))) == `null`);
    assert(S(opAddAll(J(`[1,2,null,3]`))) == `6`);
    assert(S(opAddAll(J(`["a","b"]`))) == `"ab"`);
    assert(S(opAddAll(J(`[[1],[2,3]]`))) == `[1,2,3]`);
    assert(S(opAddAll(J(`[{"a":1},{"b":2},{"a":3}]`))) == `{"a":3,"b":2}`);
    assert(S(opAddAll(J(`{"x":1,"y":2}`))) == `3`);
    assert(opAddAll(J(`[1,"a"]`)).isError);
    assert(opAddAll(J(`null`)).isError);
}

unittest // sorted permutation is stable
{
    auto keys = [J(`1`), J(`0`), J(`1`), J(`0`)];
    assert(sortedPermutation(keys) == [1u, 3, 0, 2]);
}
