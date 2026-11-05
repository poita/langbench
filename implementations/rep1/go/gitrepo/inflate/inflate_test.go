package inflate

import (
	"bytes"
	"compress/zlib"
	"math/rand"
	"testing"
)

// compress uses the standard library's compressor (not its decompressor) to
// produce test streams.
func compress(t testing.TB, data []byte, level int) []byte {
	var b bytes.Buffer
	w, err := zlib.NewWriterLevel(&b, level)
	if err != nil {
		t.Fatal(err)
	}
	w.Write(data)
	w.Close()
	return b.Bytes()
}

func sample(n int, seed int64) []byte {
	r := rand.New(rand.NewSource(seed))
	words := []string{"alpha ", "beta ", "gamma\n", "delta ", "tree ", "commit ", "\x00\x01\x02"}
	var b bytes.Buffer
	for b.Len() < n {
		b.WriteString(words[r.Intn(len(words))])
		if r.Intn(10) == 0 {
			b.WriteByte(byte(r.Intn(256)))
		}
	}
	return b.Bytes()[:n]
}

func TestRoundTrip(t *testing.T) {
	d := NewDecoder()
	inputs := [][]byte{
		{},
		[]byte("a"),
		bytes.Repeat([]byte("a"), 100000), // long overlapping matches
		bytes.Repeat([]byte("abc"), 5000),
		sample(300000, 1),
	}
	rnd := make([]byte, 70000)
	rand.New(rand.NewSource(7)).Read(rnd)
	inputs = append(inputs, rnd) // incompressible: stored blocks
	for _, level := range []int{zlib.NoCompression, zlib.BestSpeed, zlib.DefaultCompression, zlib.BestCompression, zlib.HuffmanOnly} {
		for i, in := range inputs {
			z := compress(t, in, level)
			got, n, err := d.Zlib(z, 0)
			if err != nil {
				t.Fatalf("level %d input %d: %v", level, i, err)
			}
			if !bytes.Equal(got, in) {
				t.Fatalf("level %d input %d: output mismatch", level, i)
			}
			if n != len(z)-4 {
				t.Errorf("level %d input %d: consumed %d, want %d", level, i, n, len(z)-4)
			}
		}
	}
}

func TestBackToBackStreams(t *testing.T) {
	d := NewDecoder()
	a, b := sample(5000, 3), sample(9000, 4)
	buf := append(compress(t, a, 6), compress(t, b, 6)...)
	out, n, err := d.Zlib(buf, 5000)
	if err != nil || !bytes.Equal(out, a) {
		t.Fatalf("first stream: %v", err)
	}
	out, _, err = d.Zlib(buf[n+4:], 0)
	if err != nil || !bytes.Equal(out, b) {
		t.Fatalf("second stream: %v", err)
	}
}

func TestFixedHuffman(t *testing.T) {
	// "a" compressed with fixed Huffman codes.
	d := NewDecoder()
	out, _, err := d.Zlib([]byte{0x78, 0x9c, 0x4b, 0x04, 0x00, 0x00, 0x62, 0x00, 0x62}, 0)
	if err != nil || string(out) != "a" {
		t.Fatalf("got %q, %v", out, err)
	}
}

func TestBadHeader(t *testing.T) {
	d := NewDecoder()
	for _, h := range [][]byte{
		{0x78, 0x9d, 0x03, 0x00}, // bad check bits
		{0x79, 0x9c, 0x03, 0x00}, // not deflate
		{0x78, 0xbb, 0x03, 0x00}, // preset dictionary (0xbb%31==0)
		{0x78},                   // too short
	} {
		if _, _, err := d.Zlib(h, 0); err == nil {
			t.Errorf("header % x accepted", h)
		}
	}
}

func TestCorruptAndTruncated(t *testing.T) {
	d := NewDecoder()
	in := sample(20000, 9)
	z := compress(t, in, 6)
	// Every truncation must fail cleanly (never panic, never succeed).
	for cut := 0; cut < len(z)-4; cut += 7 {
		if out, _, err := d.Zlib(z[:cut], 0); err == nil {
			t.Fatalf("truncation at %d accepted (%d bytes out)", cut, len(out))
		}
	}
	// Random bit flips must never panic or hang.
	r := rand.New(rand.NewSource(11))
	for i := 0; i < 500; i++ {
		c := append([]byte(nil), z...)
		c[2+r.Intn(len(c)-2)] ^= 1 << uint(r.Intn(8))
		d.Zlib(c, 0)
	}
}

func TestInvalidBlocks(t *testing.T) {
	d := NewDecoder()
	cases := map[string][]byte{
		"reserved block type": {0x78, 0x9c, 0x07},
		"stored bad nlen":     {0x78, 0x9c, 0x01, 0x01, 0x00, 0x00, 0x00, 0x41},
		"distance too far":    {0x78, 0x9c, 0x03, 0x02, 0x00, 0x00}, // match before start
	}
	for name, c := range cases {
		if _, _, err := d.Zlib(c, 0); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func BenchmarkInflate(b *testing.B) {
	in := sample(1<<20, 5)
	z := compress(b, in, 6)
	d := NewDecoder()
	b.SetBytes(int64(len(in)))
	for i := 0; i < b.N; i++ {
		d.Zlib(z, len(in))
	}
}
