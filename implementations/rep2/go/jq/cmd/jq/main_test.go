package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ in, want string }{
		{".users | map(.n) | add\n{\"users\":[{\"n\":1},{\"n\":2}]}\n", "3\n"},
		{"[(1,2) + (10,20)], (.[] | .a.b?)\n[{\"a\":{\"b\":1}},{\"a\":5},3]", "[11,12,21,22]\n1\nerror\n"},
		{"empty\n[]", ""},
		{".\n  {\"b\":1,\n\"a\":2}\n", "{\"b\":1,\"a\":2}\n"},
		{"1, error, 2\nnull", "1\nerror\n"},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		run(strings.NewReader(tc.in), &out)
		if out.String() != tc.want {
			t.Errorf("input %q:\n got %q\nwant %q", tc.in, out.String(), tc.want)
		}
	}
}
