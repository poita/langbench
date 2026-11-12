package inflate_test

import (
	"bytes"
	"compress/flate"
	"encoding/hex"
	"errors"
	"math/rand"
	"testing"

	"example.com/inflate"
)

func mustHex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDecodeExamples(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"empty fixed block", "0300", ""},
		{"stored byte", "010100feff41", "41"},
		{"fixed with copy", "4b4c4a862000", "616263616263616263"},
		{"stored empty", "010000ffff", ""},
	}
	for _, tc := range tests {
		got, err := inflate.Decode(mustHex(t, tc.in))
		if err != nil || hex.EncodeToString(got) != tc.want {
			t.Errorf("%s: got %x, %v; want %s", tc.name, got, err, tc.want)
		}
	}
}

func TestDecodeErrors(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want error
	}{
		{"empty stream", "", inflate.ErrTruncated},
		{"non-final block only", "00", inflate.ErrTruncated},
		{"reserved block type", "07", inflate.ErrBlockType},
		{"stored bad nlen", "010100fffe41", inflate.ErrStoredLength},
		{"stored truncated data", "010500faff41", inflate.ErrTruncated},
		{"stored truncated header", "0101", inflate.ErrTruncated},
		{"distance too far", "030200", inflate.ErrDistance},
		{"trailing byte", "030000", inflate.ErrTrailingData},
		{"truncated fixed block", "4b4c", inflate.ErrTruncated},
	}
	for _, tc := range tests {
		_, err := inflate.Decode(mustHex(t, tc.in))
		if !errors.Is(err, tc.want) {
			t.Errorf("%s: err = %v, want %v", tc.name, err, tc.want)
		}
	}
}

// bitWriter packs bit fields LSB first, as DEFLATE streams do.
type bitWriter struct {
	buf []byte
	n   uint
}

func (w *bitWriter) put(v uint32, n uint) {
	for i := uint(0); i < n; i++ {
		if w.n%8 == 0 {
			w.buf = append(w.buf, 0)
		}
		w.buf[len(w.buf)-1] |= byte(v>>i&1) << (w.n % 8)
		w.n++
	}
}

// putCode writes a Huffman code, first bit first.
func (w *bitWriter) putCode(code uint32, n uint) {
	for i := int(n) - 1; i >= 0; i-- {
		w.put(code>>uint(i)&1, 1)
	}
}

func TestDynamicSingleCodeTables(t *testing.T) {
	// One dynamic block whose literal/length code has four 2-bit codes
	// (a, b, 256, 257) and whose distance code is empty.
	var w bitWriter
	w.put(1, 1) // final
	w.put(2, 2) // dynamic
	nlit := 258 // symbols 0..257
	w.put(uint32(nlit-257), 5)
	w.put(0, 5) // HDIST+1 = 1
	// Code-length code: symbols 0 and 2 get length 1.
	order := []int{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2}
	w.put(uint32(len(order)-4), 4)
	for _, s := range order {
		if s == 0 || s == 2 {
			w.put(1, 3)
		} else {
			w.put(0, 3)
		}
	}
	// code for CL symbol 0 is "0", symbol 2 is "1".
	lens := make([]int, nlit+1)
	lens['a'], lens[256], lens['b'], lens[257] = 2, 2, 2, 2
	for _, l := range lens {
		if l == 2 {
			w.putCode(1, 1)
		} else {
			w.putCode(0, 1)
		}
	}
	// Literal codes by canonical order: a=00, b=01, 256=10, 257=11.
	w.putCode(0, 2) // a
	w.putCode(1, 2) // b
	w.putCode(2, 2) // end
	got, err := inflate.Decode(w.buf)
	if err != nil || string(got) != "ab" {
		t.Fatalf("got %q, %v", got, err)
	}

	// The same stream with a length code (257) must fail: no distance codes.
	var w2 bitWriter
	w2.buf = append([]byte(nil), w.buf...)
	w2.n = w.n - 2 // drop the end-of-block code
	w2.buf[len(w2.buf)-1] &^= 0xff << (w2.n % 8)
	w2.putCode(3, 2)
	w2.putCode(2, 2)
	if _, err := inflate.Decode(w2.buf); !errors.Is(err, inflate.ErrInvalidCode) {
		t.Fatalf("length code with empty distance table: err = %v", err)
	}
}

func TestHeaderCountLimits(t *testing.T) {
	for _, tc := range []struct{ hlit, hdist uint32 }{{30, 0}, {31, 0}, {0, 30}, {0, 31}} {
		var w bitWriter
		w.put(1, 1)
		w.put(2, 2)
		w.put(tc.hlit, 5)
		w.put(tc.hdist, 5)
		w.put(0, 4)
		w.put(0, 12)
		if _, err := inflate.Decode(w.buf); !errors.Is(err, inflate.ErrHeaderCounts) {
			t.Errorf("hlit=%d hdist=%d: err = %v", tc.hlit, tc.hdist, err)
		}
	}
}

func corpora() map[string][]byte {
	rng := rand.New(rand.NewSource(1))
	random := make([]byte, 100000)
	rng.Read(random)
	text := bytes.Repeat([]byte("the quick brown fox jumps over the lazy dog. "), 5000)
	skew := make([]byte, 200000)
	for i := range skew {
		skew[i] = byte(rng.ExpFloat64() * 4)
	}
	return map[string][]byte{
		"empty":  nil,
		"one":    {42},
		"random": random,
		"text":   text,
		"skewed": skew,
		"zeros":  make([]byte, 300000),
	}
}

func TestRoundTripWithStdlibCompressor(t *testing.T) {
	var d inflate.Decoder
	for name, data := range corpora() {
		for level := flate.HuffmanOnly; level <= flate.BestCompression; level++ {
			var buf bytes.Buffer
			w, err := flate.NewWriter(&buf, level)
			if err != nil {
				t.Fatal(err)
			}
			w.Write(data)
			w.Close()
			got, err := d.Decode(buf.Bytes())
			if err != nil {
				t.Fatalf("%s level %d: %v", name, level, err)
			}
			if !bytes.Equal(got, data) {
				t.Fatalf("%s level %d: output mismatch", name, level)
			}
		}
	}
}

func TestEveryTruncationFails(t *testing.T) {
	var buf bytes.Buffer
	w, _ := flate.NewWriter(&buf, 6)
	w.Write(bytes.Repeat([]byte("hello deflate "), 200))
	w.Close()
	stream := buf.Bytes()
	for n := 0; n < len(stream); n++ {
		if _, err := inflate.Decode(stream[:n]); err == nil {
			t.Fatalf("truncation to %d of %d bytes accepted", n, len(stream))
		}
	}
	if _, err := inflate.Decode(append(stream[:len(stream):len(stream)], 0)); !errors.Is(err, inflate.ErrTrailingData) {
		t.Fatalf("trailing byte: %v", err)
	}
}

func TestAppendKeepsPrefixAndLimitsDistance(t *testing.T) {
	var d inflate.Decoder
	out, err := d.Append([]byte("xyz"), mustHex(t, "4b4c4a862000"))
	if err != nil || string(out) != "xyzabcabcabc" {
		t.Fatalf("got %q, %v", out, err)
	}
	// A copy at distance 1 as the first symbol must not see the prefix.
	if _, err := d.Append([]byte("xyz"), mustHex(t, "030200")); !errors.Is(err, inflate.ErrDistance) {
		t.Fatalf("err = %v", err)
	}
}

func TestOverlappingCopy(t *testing.T) {
	// 'a' then length 258 distance 1 (fixed code), then end of block.
	var w bitWriter
	w.put(1, 1)
	w.put(1, 2)
	w.putCode(0x30+'a', 8)
	w.putCode(0xc0+(285-280), 8) // symbol 285
	w.putCode(0, 5)              // distance symbol 0
	w.putCode(0, 7)              // end of block
	got, err := inflate.Decode(w.buf)
	if err != nil || !bytes.Equal(got, bytes.Repeat([]byte("a"), 259)) {
		t.Fatalf("got %d bytes, %v", len(got), err)
	}
}

func FuzzDecode(f *testing.F) {
	f.Add([]byte{0x03, 0x00})
	f.Add([]byte{0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00})
	f.Add([]byte{0x01, 0x01, 0x00, 0xfe, 0xff, 0x41})
	f.Fuzz(func(t *testing.T, data []byte) {
		var d inflate.Decoder
		d.Decode(data) // must not panic
	})
}
