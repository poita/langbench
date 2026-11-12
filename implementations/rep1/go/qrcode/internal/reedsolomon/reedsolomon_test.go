package reedsolomon

import (
	"bytes"
	"testing"
)

func TestFieldTables(t *testing.T) {
	if expTable[0] != 1 || expTable[1] != 2 || expTable[8] != 0x1D {
		t.Fatalf("unexpected powers of 2: %x %x %x", expTable[0], expTable[1], expTable[8])
	}
	if expTable[255] != 1 {
		t.Fatalf("2^255 = %x, want 1", expTable[255])
	}
}

func TestMulAgainstCarryless(t *testing.T) {
	slow := func(a, b byte) byte {
		var r int
		for i := 0; i < 8; i++ {
			if b>>i&1 == 1 {
				r ^= int(a) << i
			}
		}
		for bit := 15; bit >= 8; bit-- {
			if r>>bit&1 == 1 {
				r ^= primitive << (bit - 8)
			}
		}
		return byte(r)
	}
	for a := 0; a < 256; a++ {
		for b := 0; b < 256; b++ {
			if got, want := Mul(byte(a), byte(b)), slow(byte(a), byte(b)); got != want {
				t.Fatalf("Mul(%d,%d) = %d, want %d", a, b, got, want)
			}
		}
	}
}

func TestGeneratorDegree7(t *testing.T) {
	// Well-known QR generator for 7 ECC codewords, as exponents of 2:
	// a^0 x^7 + a^87 x^6 + a^229 x^5 + a^146 x^4 + a^149 x^3 + a^238 x^2 + a^102 x + a^21
	want := []int{87, 229, 146, 149, 238, 102, 21}
	got := Generator(7)
	for i, e := range want {
		if got[i] != expTable[e] {
			t.Errorf("coefficient %d = %d, want %d", i, got[i], expTable[e])
		}
	}
}

func TestRemainderHelloWorld(t *testing.T) {
	data := []byte{32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17}
	want := []byte{196, 35, 39, 119, 235, 215, 231, 226, 93, 23}
	if got := NewEncoder(10).Remainder(data); !bytes.Equal(got, want) {
		t.Fatalf("ECC = %v, want %v", got, want)
	}
}

func TestCodewordIsMultipleOfGenerator(t *testing.T) {
	// data||ecc evaluated at every generator root 2^i must vanish.
	data := []byte("some arbitrary data to protect")
	for _, degree := range []int{7, 18, 30} {
		cw := append(append([]byte{}, data...), NewEncoder(degree).Remainder(data)...)
		for i := 0; i < degree; i++ {
			var acc byte
			for _, c := range cw {
				acc = Mul(acc, expTable[i]) ^ c
			}
			if acc != 0 {
				t.Fatalf("degree %d: syndrome %d = %d", degree, i, acc)
			}
		}
	}
}
