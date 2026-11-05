package main

import "testing"

func TestProcess(t *testing.T) {
	in := "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n-0 + 0\n007 cmp 7\n-5 * 0\n" +
		"99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n1 / 0\n0 % 0\n2 ^ -1\n" +
		"5 ^ -0\n-0 ^ -00\n5 / -0\n-3 cmp -2\n-1 / 2\n-7 % 7"
	want := "42\n-2\n-3\n-1\n0\n0\n0\n100000000000000000000\n1024\n1\n" +
		"error\nerror\nerror\n1\n1\nerror\n-1\n0\n0\n"
	if got := string(process([]byte(in))); got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
	if got := process(nil); len(got) != 0 {
		t.Errorf("empty input: got %q", got)
	}
}
