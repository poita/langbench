package hexcodec

import (
	"bytes"
	"testing"
)

func TestDecode(t *testing.T) {
	got, err := Decode([]byte("00ff7a"))
	if err != nil || !bytes.Equal(got, []byte{0, 0xff, 0x7a}) {
		t.Fatalf("got %v %v", got, err)
	}
	if got, err := Decode(nil); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	for _, bad := range []string{"0", "abc", "AB", "zz", "0g", "-"} {
		if _, err := Decode([]byte(bad)); err == nil {
			t.Errorf("Decode(%q) accepted", bad)
		}
	}
}

func TestDecodeArg(t *testing.T) {
	if got, err := DecodeArg([]byte("-")); err != nil || len(got) != 0 {
		t.Fatalf("dash: %v %v", got, err)
	}
	if _, err := DecodeArg(nil); err == nil {
		t.Fatal("empty argument accepted")
	}
	if got, err := DecodeArg([]byte("616263")); err != nil || string(got) != "abc" {
		t.Fatalf("got %q %v", got, err)
	}
	if _, err := DecodeArg([]byte("--")); err == nil {
		t.Fatal("-- accepted")
	}
}

func TestAppend(t *testing.T) {
	if got := Append([]byte("x"), []byte{0x0a, 0xff}); string(got) != "x0aff" {
		t.Fatalf("got %q", got)
	}
	if string(AppendArg(nil, nil)) != "-" || string(AppendArg(nil, []byte{1})) != "01" {
		t.Fatal("AppendArg wrong")
	}
}
