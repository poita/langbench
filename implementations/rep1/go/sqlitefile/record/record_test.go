package record

import (
	"math"
	"testing"

	"sqlitefile/value"
)

func TestVarintRoundTrip(t *testing.T) {
	vals := []int64{0, 1, 127, 128, 16383, 16384, 1<<35 + 7, 1<<56 - 1, 1 << 56, math.MaxInt64, -1, -5, math.MinInt64}
	for _, v := range vals {
		enc := PutVarint(nil, v)
		got, n := Varint(append(enc, 0xAA))
		if got != v || n != len(enc) {
			t.Errorf("round trip %d: got %d (%d bytes), encoded %d bytes", v, got, n, len(enc))
		}
		if v < 0 && len(enc) != 9 {
			t.Errorf("negative %d should use nine bytes, used %d", v, len(enc))
		}
	}
}

func TestVarintTruncated(t *testing.T) {
	if _, n := Varint([]byte{0x81}); n != 0 {
		t.Error("truncated varint should report n == 0")
	}
	if _, n := Varint(make([]byte, 0)); n != 0 {
		t.Error("empty input should report n == 0")
	}
	if _, n := Varint([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}); n != 0 {
		t.Error("eight continuation bytes without a ninth should report n == 0")
	}
}

func TestEncodeParse(t *testing.T) {
	vals := []value.Value{
		value.NullValue,
		value.NewInt(0), value.NewInt(1), value.NewInt(-1), value.NewInt(127), value.NewInt(-128),
		value.NewInt(300), value.NewInt(-40000), value.NewInt(1 << 22), value.NewInt(1 << 30),
		value.NewInt(-(1 << 31) - 1), value.NewInt(1 << 46), value.NewInt(-(1 << 47)), value.NewInt(1 << 50),
		value.NewInt(math.MaxInt64), value.NewInt(math.MinInt64),
		value.NewReal(3.25), value.NewReal(-0.5),
		value.NewText(""), value.NewText("héllo wörld"), value.NewText(string(make([]byte, 100))),
		value.NewBlob(nil), value.NewBlob([]byte{1, 2, 3}),
	}
	r, err := Parse(Encode(vals))
	if err != nil {
		t.Fatal(err)
	}
	if r.Len() != len(vals) {
		t.Fatalf("Len = %d, want %d", r.Len(), len(vals))
	}
	for i, want := range vals {
		if got := r.Value(i); got != want {
			t.Errorf("column %d: got %v, want %v", i, got, want)
		}
	}
	if got := r.Value(len(vals) + 3); !got.IsNull() {
		t.Errorf("column past the end should be NULL, got %v", got)
	}
}

func TestLargeHeader(t *testing.T) {
	vals := make([]value.Value, 200)
	for i := range vals {
		vals[i] = value.NewInt(int64(i))
	}
	r, err := Parse(Encode(vals))
	if err != nil {
		t.Fatal(err)
	}
	if r.Len() != 200 || r.Value(199).Int != 199 {
		t.Errorf("bad decode of a record with a two-byte header size")
	}
}

func TestParseCorrupt(t *testing.T) {
	bad := [][]byte{
		nil,
		{0x00},            // header size smaller than its own varint
		{0x05, 0x01},      // header claims 5 bytes, only 2 present
		{0x02, 0x01},      // body missing
		{0x02, 0x0a},      // reserved serial type 10
		{0x02, 0x1f, 'a'}, // text longer than the data
	}
	for _, b := range bad {
		if _, err := Parse(b); err == nil {
			t.Errorf("Parse(%x) succeeded, want an error", b)
		}
	}
}
