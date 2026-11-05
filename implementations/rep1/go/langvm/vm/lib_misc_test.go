package vm

import "testing"

func TestOptionResultTuple(t *testing.T) {
	s, n := Some(Int(5)), NoneV
	wantBool(t, call("isSome", s), true)
	wantBool(t, call("isSome", n), false)
	wantBool(t, call("isNone", s), false)
	wantBool(t, call("isNone", n), true)
	wantInt(t, call("unwrap", s), 5)
	wantInt(t, call("unwrapOr", s, Int(9)), 5)
	wantInt(t, call("unwrapOr", n, Int(9)), 9)
	wantPanic(t, "unwrap of None", "unwrap", n)

	ok, er := Ok(Int(1)), Err(GoStr("bad"))
	wantBool(t, call("isOk", ok), true)
	wantBool(t, call("isOk", er), false)
	wantBool(t, call("isErr", ok), false)
	wantBool(t, call("isErr", er), true)
	wantInt(t, call("unwrapOk", ok), 1)
	wantStr(t, call("unwrapErr", er), "bad")
	wantPanic(t, "unwrap of Err", "unwrapOk", er)
	wantPanic(t, "unwrap of Ok", "unwrapErr", ok)

	p := Tuple([]Value{Int(1), GoStr("x")})
	wantInt(t, call("fst", p), 1)
	wantStr(t, call("snd", p), "x")
}
