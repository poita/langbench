package queries

import "testing"

func TestProcess(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n", "42\n-2\n-3\n-1\n"},
		{"12 + 30", "42\n"}, // no trailing newline
		{"-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n",
			"0\n0\n0\n100000000000000000000\n1024\n1\n"},
		{"1 / 0\n0 % 0\n2 ^ -1\n5 / -0\n5 ^ -0\n-0 ^ -00\n", "error\nerror\nerror\nerror\n1\n1\n"},
		{"-3 cmp -2\n2 cmp 1\n5 cmp 5\n", "-1\n1\n0\n"},
		{"-123456789012345678901234567890 * 987654321098765432109876543210\n",
			"-121932631137021795226185032733622923332237463801111263526900\n"},
		{"-1 / 2\n-7 % 7\n7 % -2\n", "0\n0\n1\n"},
	}
	for _, c := range cases {
		if got := string(Process([]byte(c.in), nil)); got != c.want {
			t.Errorf("Process(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
