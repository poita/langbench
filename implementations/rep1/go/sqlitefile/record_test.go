package sqlitefile

import (
	"bytes"
	"math"
	"testing"
)

func TestVarint(t *testing.T) {
	vals := []int64{0, 1, 127, 128, 16383, 16384, 1<<32 + 5, 1<<56 - 1, 1 << 56, math.MaxInt64, -1, math.MinInt64}
	for _, v := range vals {
		enc := putVarint(uint64(v))
		got, n := getVarint(append(enc, 0xAA, 0xBB))
		if n != len(enc) || int64(got) != v {
			t.Errorf("varint %d: decoded %d using %d of %d bytes", v, int64(got), n, len(enc))
		}
		if v < 0 && len(enc) != 9 {
			t.Errorf("negative varint %d should be 9 bytes, got %d", v, len(enc))
		}
		if _, n := getVarint(enc[:len(enc)-1]); n != 0 && len(enc) > 1 {
			t.Errorf("truncated varint %d accepted", v)
		}
	}
}

func TestRecordRoundTrip(t *testing.T) {
	vals := []Value{
		Null(), Int(0), Int(1), Int(-1), Int(127), Int(-128), Int(300), Int(-300),
		Int(70000), Int(-70000), Int(1 << 30), Int(-(1 << 30)), Int(1 << 40), Int(-(1 << 40)),
		Int(math.MaxInt64), Int(math.MinInt64), Real(3.5), Real(-0.25),
		Text(""), Text("hello"), Blob(nil), Blob([]byte{1, 2, 3}),
	}
	var rec record
	if err := rec.parse(encodeRecord(vals)); err != nil {
		t.Fatal(err)
	}
	if rec.numCols() != len(vals) {
		t.Fatalf("numCols = %d, want %d", rec.numCols(), len(vals))
	}
	for i, want := range vals {
		got := rec.value(i)
		if got.Kind != want.Kind || Compare(got, want) != 0 || !bytes.Equal(got.B, want.B) {
			t.Errorf("column %d: got %v (%v), want %v (%v)", i, got.Kind, got, want.Kind, want)
		}
	}
	if !rec.value(len(vals)).IsNull() {
		t.Error("columns past the end of a short record must read as NULL")
	}
}

func TestRecordCorrupt(t *testing.T) {
	good := encodeRecord([]Value{Int(1 << 40), Text("abc")})
	var rec record
	if err := rec.parse(good[:len(good)-1]); err == nil {
		t.Error("truncated body accepted")
	}
	if err := rec.parse([]byte{9, 1}); err == nil {
		t.Error("header size past payload accepted")
	}
	if err := rec.parse([]byte{2, 10}); err == nil {
		t.Error("reserved serial type 10 accepted")
	}
	if err := rec.parse(nil); err == nil {
		t.Error("empty payload accepted")
	}
}
