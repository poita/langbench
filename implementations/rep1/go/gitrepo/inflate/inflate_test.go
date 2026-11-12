package inflate

import (
	"bytes"
	"compress/flate" // oracle encoder, tests only
	"compress/zlib"
	"errors"
	"math/rand"
	"testing"
)

func zlibBytes(t *testing.T, data []byte, level int) []byte {
	t.Helper()
	var buf bytes.Buffer
	w, err := zlib.NewWriterLevel(&buf, level)
	if err != nil {
		t.Fatal(err)
	}
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func sampleInputs() map[string][]byte {
	rng := rand.New(rand.NewSource(7))
	random := make([]byte, 70000)
	rng.Read(random)
	text := bytes.Repeat([]byte("the quick brown fox jumps over the lazy dog\n"), 3000)
	runs := bytes.Repeat([]byte{'a'}, 100000)
	return map[string][]byte{
		"empty":  {},
		"one":    {'x'},
		"text":   text,
		"runs":   runs,
		"random": random,
	}
}

func TestRoundTripLevels(t *testing.T) {
	for name, data := range sampleInputs() {
		for _, level := range []int{zlib.NoCompression, zlib.BestSpeed, zlib.DefaultCompression, zlib.BestCompression, zlib.HuffmanOnly} {
			comp := zlibBytes(t, data, level)
			got, n, err := Zlib(comp, len(data))
			if err != nil {
				t.Fatalf("%s level %d: %v", name, level, err)
			}
			if !bytes.Equal(got, data) {
				t.Fatalf("%s level %d: wrong output", name, level)
			}
			if n != len(comp) {
				t.Fatalf("%s level %d: consumed %d of %d", name, level, n, len(comp))
			}
		}
	}
}

func TestConsumedStopsAtStreamEnd(t *testing.T) {
	a := zlibBytes(t, []byte("first object"), zlib.DefaultCompression)
	b := zlibBytes(t, []byte("second object"), zlib.DefaultCompression)
	got, n, err := Zlib(append(append([]byte{}, a...), b...), 0)
	if err != nil || string(got) != "first object" || n != len(a) {
		t.Fatalf("got %q, %d, %v; want first object, %d", got, n, err, len(a))
	}
}

func TestRawDeflateBlockTypes(t *testing.T) {
	// compress/flate emits stored, fixed and dynamic blocks depending on input.
	for name, data := range sampleInputs() {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.BestCompression)
		w.Write(data)
		w.Close()
		got, n, err := Deflate(buf.Bytes(), 0)
		if err != nil || !bytes.Equal(got, data) || n != buf.Len() {
			t.Errorf("%s: err=%v n=%d/%d equal=%v", name, err, n, buf.Len(), bytes.Equal(got, data))
		}
	}
}

func TestBadHeaders(t *testing.T) {
	good := zlibBytes(t, []byte("hello"), zlib.DefaultCompression)
	cases := map[string][]byte{
		"empty":       {},
		"short":       {0x78},
		"not deflate": {0x79, 0x9c}, // CM = 9
		"bad check":   {0x78, 0x9d},
		"dictionary":  {0x78, 0xbb}, // FDICT set, check bits valid
	}
	for name, in := range cases {
		if _, _, err := Zlib(append(in, good[2:]...), 0); !errors.Is(err, ErrCorrupt) {
			t.Errorf("%s: err = %v, want ErrCorrupt", name, err)
		}
	}
}

func TestCorruptStreams(t *testing.T) {
	good := zlibBytes(t, bytes.Repeat([]byte("abcdefgh"), 500), zlib.DefaultCompression)

	bad := append([]byte{}, good...)
	bad[len(bad)-1] ^= 0xff
	if _, _, err := Zlib(bad, 0); !errors.Is(err, ErrCorrupt) {
		t.Errorf("bad adler: err = %v", err)
	}
	for _, cut := range []int{3, len(good) / 2, len(good) - 1} {
		if _, _, err := Zlib(good[:cut], 0); !errors.Is(err, ErrCorrupt) {
			t.Errorf("truncated to %d: err = %v", cut, err)
		}
	}
	// Reserved block type 3.
	if _, _, err := Deflate([]byte{0x07}, 0); !errors.Is(err, ErrCorrupt) {
		t.Errorf("reserved block: err = %v", err)
	}
	// Stored block with wrong complement.
	if _, _, err := Deflate([]byte{0x01, 0x01, 0x00, 0x00, 0x00, 'x'}, 0); !errors.Is(err, ErrCorrupt) {
		t.Errorf("stored mismatch: err = %v", err)
	}
	// Fixed block whose first distance reaches before the output start.
	if _, _, err := Deflate([]byte{0x03, 0x02, 0x00}, 0); err == nil {
		t.Error("expected error for fixed block with no end")
	}
}

func TestNoPanicOnGarbage(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	for i := 0; i < 2000; i++ {
		b := make([]byte, rng.Intn(64))
		rng.Read(b)
		Deflate(b, 0)
		Zlib(append([]byte{0x78, 0x9c}, b...), 0)
	}
}

func TestAdler32(t *testing.T) {
	if got := adler32([]byte("Wikipedia")); got != 0x11E60398 {
		t.Errorf("adler32 = %08x", got)
	}
}

func BenchmarkInflateText(b *testing.B) {
	data := bytes.Repeat([]byte("the quick brown fox jumps over the lazy dog\n"), 20000)
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	w.Write(data)
	w.Close()
	b.SetBytes(int64(len(data)))
	for i := 0; i < b.N; i++ {
		if _, _, err := Zlib(buf.Bytes(), len(data)); err != nil {
			b.Fatal(err)
		}
	}
}
