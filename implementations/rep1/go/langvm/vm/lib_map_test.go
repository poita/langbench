package vm

import "testing"

func TestMaps(t *testing.T) {
	mp := call("mapNew")
	wantInt(t, call("mapLen", mp), 0)
	wantBool(t, call("mapHas", mp, GoStr("a")), false)
	if call("mapGet", mp, GoStr("a")).P.Var != VarNone {
		t.Error("get on empty")
	}
	call("mapSet", mp, GoStr("b"), Int(1))
	call("mapSet", mp, GoStr("a"), Int(2))
	call("mapSet", mp, GoStr("c"), Int(3))
	call("mapSet", mp, GoStr("b"), Int(10)) // keeps position
	wantInt(t, call("mapLen", mp), 3)
	wantBool(t, call("mapHas", mp, GoStr("a")), true)
	g := call("mapGet", mp, GoStr("b"))
	if g.P.Var != VarSome || g.P.V[0].N != 10 {
		t.Error("get")
	}
	wantInt(t, call("mapGetOr", mp, GoStr("a"), Int(99)), 2)
	wantInt(t, call("mapGetOr", mp, GoStr("z"), Int(99)), 99)
	if !eqStrs(listStrs(call("keysOf", mp)), []string{"b", "a", "c"}) {
		t.Error("keys order")
	}
	if !eqInts(listInts(call("valuesOf", mp)), []int64{10, 2, 3}) {
		t.Error("values order")
	}
	ps := call("pairsOf", mp)
	if len(ps.P.V) != 3 || ps.P.V[1].P.Kind != KTuple || gs(call("fst", ps.P.V[1])) != "a" || call("snd", ps.P.V[1]).N != 2 {
		t.Error("pairs")
	}
	wantBool(t, call("mapDel", mp, GoStr("a")), true)
	wantBool(t, call("mapDel", mp, GoStr("a")), false)
	call("mapSet", mp, GoStr("a"), Int(7)) // re-insert goes last
	if !eqStrs(listStrs(call("keysOf", mp)), []string{"b", "c", "a"}) {
		t.Error("reinsert order", listStrs(call("keysOf", mp)))
	}
	cp := call("mapCopy", mp)
	call("mapSet", cp, GoStr("q"), Int(0))
	wantInt(t, call("mapLen", mp), 3)
	wantInt(t, call("mapLen", cp), 4)
	if !eqStrs(listStrs(call("keysOf", cp)), []string{"b", "c", "a", "q"}) {
		t.Error("copy order")
	}
	call("mapClear", mp)
	wantInt(t, call("mapLen", mp), 0)
	wantBool(t, call("mapHas", mp, GoStr("b")), false)
	if len(call("keysOf", mp).P.V) != 0 || len(call("pairsOf", mp).P.V) != 0 {
		t.Error("keys of empty")
	}
	call("mapSet", mp, GoStr("x"), Int(1))
	wantInt(t, call("mapLen", mp), 1)

	// other key kinds, and many entries with deletions
	im := call("mapNew")
	for i := int64(0); i < 200; i++ {
		call("mapSet", im, Int(i*7), Int(i))
	}
	for i := int64(0); i < 200; i += 2 {
		call("mapDel", im, Int(i*7))
	}
	ks := listInts(call("keysOf", im))
	if len(ks) != 100 || ks[0] != 7 || ks[99] != 199*7 {
		t.Error("int keys", len(ks))
	}
	cm := call("mapNew")
	call("mapSet", cm, Char('x'), Bool(true))
	call("mapSet", cm, Bool(true), Bool(false))
	wantBool(t, call("mapGetOr", cm, Char('x'), Bool(false)), true)
	bm := call("mapNew")
	call("mapSet", bm, Bool(true), Int(1))
	call("mapSet", bm, Bool(false), Int(2))
	wantInt(t, call("mapGetOr", bm, Bool(false), Int(0)), 2)
}
