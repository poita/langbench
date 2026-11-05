package inflate

import (
	"bytes"
	"compress/flate"
	"encoding/hex"
	"errors"
	"math/rand"
	"testing"
)

func unhex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// bitWriter assembles streams bit by bit for hand-made test cases.
type bitWriter struct {
	buf  []byte
	nbit int
}

// num writes an n-bit number LSB first.
func (w *bitWriter) num(v uint32, n int) *bitWriter {
	for i := 0; i < n; i++ {
		if w.nbit%8 == 0 {
			w.buf = append(w.buf, 0)
		}
		w.buf[len(w.buf)-1] |= byte(v>>uint(i)&1) << uint(w.nbit%8)
		w.nbit++
	}
	return w
}

// code writes a Huffman code given as a string of 0/1, first bit first.
func (w *bitWriter) code(s string) *bitWriter {
	for _, c := range s {
		w.num(uint32(c-'0'), 1)
	}
	return w
}

func (w *bitWriter) bytes() []byte { return w.buf }

// fixedCode returns the fixed-Huffman code of a literal/length symbol.
func fixedCode(sym int) string {
	bin := func(v, n int) string {
		s := make([]byte, n)
		for i := range s {
			s[i] = '0' + byte(v>>uint(n-1-i)&1)
		}
		return string(s)
	}
	switch {
	case sym < 144:
		return bin(0x30+sym, 8)
	case sym < 256:
		return bin(0x190+sym-144, 9)
	case sym < 280:
		return bin(sym-256, 7)
	default:
		return bin(0xc0+sym-280, 8)
	}
}

func TestDecodeValid(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"empty fixed block", "0300", ""},
		{"stored one byte", "010100feff41", "41"},
		{"fixed with backref", "4b4c4a862000", "616263616263616263"},
		{"stored empty then fixed empty", "00 0000ffff 0300", ""},
		{"two stored blocks", "00 0100feff41 01 0100feff42", "4142"},
	}
	for _, tc := range tests {
		in := bytes.ReplaceAll([]byte(tc.in), []byte(" "), nil)
		got, err := Decode(unhex(t, string(in)))
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if hex.EncodeToString(got) != tc.want {
			t.Errorf("%s: got %x, want %s", tc.name, got, tc.want)
		}
	}
}

func TestDecodeErrors(t *testing.T) {
	tests := []struct {
		name string
		in   []byte
		want error
	}{
		{"empty stream", nil, ErrTruncated},
		{"only header bits", []byte{0x00}, ErrTruncated},
		{"non-final block only", unhex(t, "000000ffff"), ErrTruncated},
		{"stored LEN cut", unhex(t, "010100"), ErrTruncated},
		{"stored data cut", unhex(t, "010200fdff41"), ErrTruncated},
		{"block type 3", []byte{0x07, 0x00}, ErrBlockType},
		{"stored bad NLEN", unhex(t, "010100ffff41"), ErrStoredLength},
		{"trailing byte", unhex(t, "030000"), ErrTrailingData},
		{"trailing after stored", unhex(t, "010100feff4100"), ErrTrailingData},
		{"distance too far", unhex(t, "030200"), ErrDistance},
		{"missing final EOB", unhex(t, "4b4c4a"), ErrTruncated},
		{"reserved literal 286", new(bitWriter).num(1, 1).num(1, 2).code(fixedCode(286)).bytes(), ErrInvalidSymbol},
		{"reserved distance 30", new(bitWriter).num(1, 1).num(1, 2).code(fixedCode('a')).code(fixedCode(257)).code("11110").bytes(), ErrInvalidSymbol},
		{"HLIT too big", new(bitWriter).num(1, 1).num(2, 2).num(30, 5).num(0, 5).num(0, 4).num(0, 32).bytes(), ErrTooManyCodes},
		{"HDIST too big", new(bitWriter).num(1, 1).num(2, 2).num(0, 5).num(30, 5).num(0, 4).num(0, 32).bytes(), ErrTooManyCodes},
	}
	for _, tc := range tests {
		got, err := Decode(tc.in)
		if !errors.Is(err, tc.want) || got != nil {
			t.Errorf("%s: got (%x, %v), want %v", tc.name, got, err, tc.want)
		}
	}
}

// dynHeader writes a dynamic block header declaring nlit literal/length and
// ndist distance codes, with the code-length alphabet given by clLens
// (indexed by code-length symbol 0..18). The caller then writes the code
// lengths using the code-length code, given by clCodes.
func dynHeader(w *bitWriter, nlit, ndist int, clLens [19]int) {
	w.num(0, 1).num(2, 2) // not final (caller may patch), dynamic
	w.num(uint32(nlit-257), 5).num(uint32(ndist-1), 5).num(15, 4)
	for _, s := range codeLengthOrder {
		w.num(uint32(clLens[s]), 3)
	}
}

// Code-length code used by the hand-made dynamic blocks: symbols 0, 1, 2 and
// 18 all have length 2, which is complete; canonical codes 00, 01, 10, 11.
var (
	testCLLens  = [19]int{0: 2, 1: 2, 2: 2, 18: 2}
	testCLCodes = map[int]string{0: "00", 1: "01", 2: "10", 18: "11"}
)

// dynBlock starts a final dynamic block whose literal/length code has the
// given non-zero lengths (symbol -> length, lengths 0..2 only; nlit symbols
// in total) and whose distance code has lengths dist.
func dynBlock(nlit int, lit map[int]int, dist []int) *bitWriter {
	w := &bitWriter{}
	dynHeader(w, nlit, len(dist), testCLLens)
	w.buf[0] |= 1 // BFINAL
	all := make([]int, nlit)
	for s, l := range lit {
		all[s] = l
	}
	all = append(all, dist...)
	for i := 0; i < len(all); {
		if all[i] == 0 {
			run := 0
			for i+run < len(all) && all[i+run] == 0 && run < 138 {
				run++
			}
			if run >= 11 {
				w.code(testCLCodes[18]).num(uint32(run-11), 7)
				i += run
				continue
			}
		}
		w.code(testCLCodes[all[i]])
		i++
	}
	return w
}

func TestDynamicBlocks(t *testing.T) {
	// Literal/length code: 256 -> "0", 65 ('A') -> "10", 66 ('B') -> "11".
	abc := map[int]int{65: 2, 66: 2, 256: 1}

	t.Run("literals only, empty distance set", func(t *testing.T) {
		w := dynBlock(257, abc, []int{0})
		w.code("10").code("11").code("11").code("0")
		got, err := Decode(w.bytes())
		if err != nil || string(got) != "ABB" {
			t.Fatalf("got (%q, %v)", got, err)
		}
	})
	t.Run("single 1-bit distance code", func(t *testing.T) {
		w := dynBlock(257, abc, []int{1})
		w.code("10").code("0")
		got, err := Decode(w.bytes())
		if err != nil || string(got) != "A" {
			t.Fatalf("got (%q, %v)", got, err)
		}
	})
	t.Run("single 1-bit literal/length code", func(t *testing.T) {
		w := dynBlock(257, map[int]int{256: 1}, []int{0})
		w.code("0")
		got, err := Decode(w.bytes())
		if err != nil || len(got) != 0 {
			t.Fatalf("got (%q, %v)", got, err)
		}
		// The unassigned bit 1 is an error.
		w = dynBlock(257, map[int]int{256: 1}, []int{0})
		w.code("1").code("0")
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrInvalidCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("length code with empty distance set", func(t *testing.T) {
		// 256 -> "0", 257 -> "1"
		w := dynBlock(258, map[int]int{256: 1, 257: 1}, []int{0})
		w.code("1").code("0")
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrInvalidCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("invalid pattern in incomplete distance table", func(t *testing.T) {
		w := dynBlock(258, map[int]int{256: 1, 257: 1}, []int{1})
		w.code("1").code("1") // length 3, distance bit 1 is not a code
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrInvalidCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("distance before start", func(t *testing.T) {
		w := dynBlock(258, map[int]int{256: 1, 257: 1}, []int{1})
		w.code("1").code("0")
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrDistance) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("missing end of block", func(t *testing.T) {
		w := dynBlock(257, map[int]int{65: 1, 66: 1}, []int{0})
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrMissingEndOfBlock) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("incomplete literal/length code", func(t *testing.T) {
		w := dynBlock(257, map[int]int{65: 2, 256: 1}, []int{0})
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrIncompleteCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("single 2-bit literal/length code", func(t *testing.T) {
		w := dynBlock(257, map[int]int{256: 2}, []int{0})
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrIncompleteCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("over-subscribed distance code", func(t *testing.T) {
		w := dynBlock(257, abc, []int{1, 1, 1})
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrOverSubscribed) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("incomplete code-length code", func(t *testing.T) {
		var l [19]int
		l[0], l[1] = 1, 2
		w := &bitWriter{}
		dynHeader(w, 257, 1, l)
		w.buf[0] |= 1
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrIncompleteCode) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("repeat 16 without previous", func(t *testing.T) {
		var l [19]int
		l[16], l[0] = 1, 1 // canonical: sym 0 -> "0", sym 16 -> "1"
		w := &bitWriter{}
		dynHeader(w, 257, 1, l)
		w.code("1").num(0, 2)
		w.buf[0] |= 1
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrBadRepeat) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("repeat overflow", func(t *testing.T) {
		var l [19]int
		l[18], l[0] = 1, 1 // sym 0 -> "0", sym 18 -> "1"
		w := &bitWriter{}
		dynHeader(w, 257, 1, l)
		for i := 0; i < 3; i++ { // 3*138 > 258
			w.code("1").num(127, 7)
		}
		w.buf[0] |= 1
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrBadRepeat) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("truncated inside block", func(t *testing.T) {
		w := dynBlock(257, abc, []int{0})
		for w.nbit%8 != 0 { // fill the last byte so no zero padding looks like EOB
			w.code("1")
		}
		if _, err := Decode(w.bytes()); !errors.Is(err, ErrTruncated) {
			t.Errorf("err = %v", err)
		}
	})
}

func TestBackReferences(t *testing.T) {
	// 'a' then copy len 10 dist 1 -> eleven 'a'.
	w := new(bitWriter).num(1, 1).num(1, 2)
	w.code(fixedCode('a')).code(fixedCode(264)).code("00000").code(fixedCode(256))
	got, err := Decode(w.bytes())
	if err != nil || string(got) != "aaaaaaaaaaa" {
		t.Fatalf("got (%q, %v)", got, err)
	}

	// Pattern repetition, distance 3 length 258 via symbol 285.
	w = new(bitWriter).num(1, 1).num(1, 2)
	w.code(fixedCode('x')).code(fixedCode('y')).code(fixedCode('z'))
	w.code(fixedCode(285)).code("00010").code(fixedCode(256))
	got, err = Decode(w.bytes())
	want := bytes.Repeat([]byte("xyz"), 87)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("got (%q, %v)", got, err)
	}

	// Symbol 284 with extra value 31 is length 258.
	w = new(bitWriter).num(1, 1).num(1, 2)
	w.code(fixedCode('q')).code(fixedCode(284)).num(31, 5).code("00000").code(fixedCode(256))
	got, err = Decode(w.bytes())
	if err != nil || !bytes.Equal(got, bytes.Repeat([]byte("q"), 259)) {
		t.Fatalf("284/31: got %d bytes, %v", len(got), err)
	}

	// Distance reaching into a previous block.
	w = new(bitWriter).num(0, 1).num(1, 2).code(fixedCode('m')).code(fixedCode(256))
	w.num(1, 1).num(1, 2).code(fixedCode(257)).code("00000").code(fixedCode(256))
	got, err = Decode(w.bytes())
	if err != nil || string(got) != "mmmm" {
		t.Fatalf("cross-block: got (%q, %v)", got, err)
	}
}

func compress(t testing.TB, data []byte, level int) []byte {
	t.Helper()
	var buf bytes.Buffer
	fw, err := flate.NewWriter(&buf, level)
	if err != nil {
		t.Fatal(err)
	}
	fw.Write(data)
	fw.Close()
	return buf.Bytes()
}

func testInputs() map[string][]byte {
	rng := rand.New(rand.NewSource(1))
	random := make([]byte, 200000)
	rng.Read(random)
	text := make([]byte, 0, 300000)
	words := []string{"the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog\n", "inflate ", "huffman "}
	for len(text) < 300000 {
		text = append(text, words[rng.Intn(len(words))]...)
	}
	skew := make([]byte, 300000)
	for i := range skew {
		skew[i] = byte(rng.ExpFloat64() * 12)
	}
	return map[string][]byte{
		"empty":  {},
		"one":    {42},
		"zeros":  make([]byte, 100000),
		"random": random,
		"text":   text,
		"skewed": skew,
	}
}

func TestRoundTrip(t *testing.T) {
	d := NewDecoder() // reused across all cases to exercise table reuse
	for name, data := range testInputs() {
		for _, level := range []int{flate.NoCompression, flate.BestSpeed, 6, flate.BestCompression, flate.HuffmanOnly} {
			got, err := d.Decode(compress(t, data, level))
			if err != nil {
				t.Errorf("%s level %d: %v", name, level, err)
				continue
			}
			if !bytes.Equal(got, data) {
				t.Errorf("%s level %d: output differs", name, level)
			}
		}
	}
}

func TestTruncationAlwaysFails(t *testing.T) {
	data := testInputs()["text"][:5000]
	for _, level := range []int{flate.NoCompression, flate.HuffmanOnly, 6} {
		c := compress(t, data, level)
		for n := 0; n < len(c); n++ {
			if _, err := Decode(c[:n]); err == nil {
				t.Fatalf("level %d: prefix of %d/%d bytes decoded without error", level, n, len(c))
			}
		}
		if _, err := Decode(append(c, 0)); !errors.Is(err, ErrTrailingData) {
			t.Errorf("level %d: trailing byte: %v", level, err)
		}
	}
}

func TestCorruptionNeverPanics(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	c := compress(t, testInputs()["text"][:20000], 6)
	for i := 0; i < 3000; i++ {
		m := append([]byte(nil), c...)
		for j := 0; j < 1+rng.Intn(3); j++ {
			m[rng.Intn(len(m))] ^= 1 << uint(rng.Intn(8))
		}
		Decode(m) // result irrelevant; must not panic or hang
	}
}

func TestDecoderReusable(t *testing.T) {
	d := NewDecoder()
	if _, err := d.Decode([]byte{7, 0}); err == nil {
		t.Fatal("expected error")
	}
	got, err := d.Decode(unhex(t, "4b4c4a862000"))
	if err != nil || hex.EncodeToString(got) != "616263616263616263" {
		t.Fatalf("got (%x, %v)", got, err)
	}
	// Results from earlier calls are not clobbered by later ones.
	again, _ := d.Decode(unhex(t, "010100feff41"))
	if hex.EncodeToString(got) != "616263616263616263" || string(again) != "A" {
		t.Error("results alias each other")
	}
}

func BenchmarkDecode(b *testing.B) {
	data := testInputs()["text"]
	c := compress(b, data, 6)
	b.SetBytes(int64(len(data)))
	d := NewDecoder()
	for i := 0; i < b.N; i++ {
		if _, err := d.Decode(c); err != nil {
			b.Fatal(err)
		}
	}
}
