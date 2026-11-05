package inflate

import (
	"errors"
	"testing"
)

// lookup decodes one symbol from the low bits of v (LSB first), mirroring the
// two-level lookup done by the decoder. It returns the symbol and the number
// of bits consumed, or ok=false for an invalid pattern.
func lookup(t *huffTable, v uint32) (sym, nbits int, ok bool) {
	e := t.entries[v&(1<<t.root-1)]
	used := 0
	if e&entrySub != 0 {
		v >>= t.root
		used = int(t.root)
		e = t.entries[int(e>>entryShift)+int(v&(1<<(e&0xff)-1))]
	}
	l := int(e & 0xff)
	if l == 0 {
		return 0, 0, false
	}
	return int(e >> entryShift), used + l, true
}

func TestBuildCanonicalCodes(t *testing.T) {
	// RFC 1951 3.2.2 example: lengths (3,3,3,3,3,2,4,4) give
	// A=010 B=011 C=100 D=101 E=110 F=00 G=1110 H=1111.
	lengths := []uint8{3, 3, 3, 3, 3, 2, 4, 4}
	codes := []string{"010", "011", "100", "101", "110", "00", "1110", "1111"}
	var tab huffTable
	if err := tab.build(lengths, 3, ruleComplete); err != nil { // root < max forces a subtable
		t.Fatal(err)
	}
	for sym, code := range codes {
		// Huffman codes are packed MSB first: first bit read is bit 0.
		var v uint32
		for i, c := range code {
			if c == '1' {
				v |= 1 << uint(i)
			}
		}
		// Garbage above the code must not matter.
		for _, junk := range []uint32{0, 0xfff0} {
			got, n, ok := lookup(&tab, v|junk<<uint(len(code)))
			if !ok || got != sym || n != len(code) {
				t.Errorf("code %s: got (%d,%d,%v), want (%d,%d,true)", code, got, n, ok, sym, len(code))
			}
		}
	}
}

func TestBuildLongCodes(t *testing.T) {
	// A maximally skewed code: lengths 1,2,...,14,15,15.
	lengths := make([]uint8, 16)
	for i := 0; i < 15; i++ {
		lengths[i] = uint8(i + 1)
	}
	lengths[15] = 15
	for _, root := range []uint{4, 8, 10} {
		var tab huffTable
		if err := tab.build(lengths, root, ruleComplete); err != nil {
			t.Fatal(err)
		}
		for sym := 0; sym < 16; sym++ {
			// Symbol i < 15 has code 1^i 0 (MSB first), so the bit stream is
			// i ones then a zero; the last symbol is 15 ones.
			var v uint32
			l := int(lengths[sym])
			for j := 0; j < sym; j++ {
				v |= 1 << uint(j)
			}
			if sym == 15 {
				v = 1<<15 - 1
			}
			got, n, ok := lookup(&tab, v)
			if !ok || got != sym || n != l {
				t.Errorf("root %d sym %d: got (%d,%d,%v), want (%d,%d,true)", root, sym, got, n, ok, sym, l)
			}
		}
	}
}

func TestBuildRules(t *testing.T) {
	tests := []struct {
		name    string
		lengths []uint8
		rule    codeRule
		want    error
	}{
		{"complete", []uint8{1, 1}, ruleComplete, nil},
		{"over-subscribed", []uint8{1, 1, 1}, ruleSingleOrEmpty, ErrOverSubscribed},
		{"incomplete", []uint8{1, 2}, ruleSingleOrEmpty, ErrIncompleteCode},
		{"empty strict", []uint8{0, 0}, ruleComplete, ErrIncompleteCode},
		{"empty strict single", []uint8{0, 0}, ruleSingle, ErrIncompleteCode},
		{"empty allowed", []uint8{0, 0}, ruleSingleOrEmpty, nil},
		{"single bit strict", []uint8{0, 1}, ruleComplete, ErrIncompleteCode},
		{"single bit allowed", []uint8{0, 1}, ruleSingle, nil},
		{"single 2-bit code", []uint8{2}, ruleSingleOrEmpty, ErrIncompleteCode},
		{"two codes incomplete", []uint8{1, 0, 0, 3}, ruleSingleOrEmpty, ErrIncompleteCode},
	}
	for _, tc := range tests {
		var tab huffTable
		if err := tab.build(tc.lengths, 4, tc.rule); !errors.Is(err, tc.want) {
			t.Errorf("%s: err = %v, want %v", tc.name, err, tc.want)
		}
	}
}

func TestSingleCodeRejectsOtherBit(t *testing.T) {
	var tab huffTable
	if err := tab.build([]uint8{0, 1}, 8, ruleSingle); err != nil {
		t.Fatal(err)
	}
	if sym, n, ok := lookup(&tab, 0); !ok || sym != 1 || n != 1 {
		t.Errorf("bit 0: got (%d,%d,%v)", sym, n, ok)
	}
	if _, _, ok := lookup(&tab, 1); ok {
		t.Error("bit 1 accepted")
	}
}

func TestTableReuseClearsOldEntries(t *testing.T) {
	var tab huffTable
	big := make([]uint8, 300)
	// 256 codes of 8 bits: complete, fills the whole root table and more.
	for i := 0; i < 256; i++ {
		big[i] = 8
	}
	if err := tab.build(big, 10, ruleComplete); err != nil {
		t.Fatal(err)
	}
	if err := tab.build([]uint8{0, 1}, 10, ruleSingle); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := lookup(&tab, 1); ok {
		t.Error("stale entry survived rebuild")
	}
}

func TestFixedTables(t *testing.T) {
	lit, dist := fixedTables()
	// Literal 0 is 00110000 (MSB first), end-of-block is 0000000.
	rev := func(code string) uint32 {
		var v uint32
		for i, c := range code {
			if c == '1' {
				v |= 1 << uint(i)
			}
		}
		return v
	}
	if sym, n, ok := lookup(lit, rev("00110000")); !ok || sym != 0 || n != 8 {
		t.Errorf("literal 0: (%d,%d,%v)", sym, n, ok)
	}
	if sym, n, ok := lookup(lit, rev("0000000")); !ok || sym != 256 || n != 7 {
		t.Errorf("EOB: (%d,%d,%v)", sym, n, ok)
	}
	if sym, n, ok := lookup(lit, rev("110010000")); !ok || sym != 144 || n != 9 {
		t.Errorf("symbol 144: (%d,%d,%v)", sym, n, ok)
	}
	if sym, n, ok := lookup(lit, rev("11000111")); !ok || sym != 287 || n != 8 {
		t.Errorf("symbol 287: (%d,%d,%v)", sym, n, ok)
	}
	if sym, n, ok := lookup(dist, rev("11111")); !ok || sym != 31 || n != 5 {
		t.Errorf("distance 31: (%d,%d,%v)", sym, n, ok)
	}
}
