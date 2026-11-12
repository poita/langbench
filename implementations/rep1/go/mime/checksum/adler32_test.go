package checksum

import "testing"

func TestAdler32(t *testing.T) {
	tests := []struct{ in, want string }{
		{"", "00000001"},
		{"Wikipedia", "11e60398"},
		{"caf\xe9", "04680214"},
		{"\x00\x01\x02\x03", "000e0007"},
	}
	for _, tc := range tests {
		if got := Adler32Hex([]byte(tc.in)); got != tc.want {
			t.Errorf("Adler32(%q) = %s, want %s", tc.in, got, tc.want)
		}
	}
}
