package toml

import "testing"

func TestScalars(t *testing.T) {
	tests := []struct {
		in   string
		typ  ValueType
		want string
	}{
		{"0", Integer, "0"},
		{"+0", Integer, "0"},
		{"-0", Integer, "0"},
		{"+17", Integer, "17"},
		{"-17", Integer, "-17"},
		{"1_000", Integer, "1000"},
		{"0xDEAD_beef", Integer, "3735928559"},
		{"0o755", Integer, "493"},
		{"0b1101", Integer, "13"},
		{"0x0000000000000000000001", Integer, "1"},
		{"9223372036854775807", Integer, "9223372036854775807"},
		{"-9223372036854775808", Integer, "-9223372036854775808"},
		{"0x7FFFFFFFFFFFFFFF", Integer, "9223372036854775807"},
		{"true", Bool, "true"},
		{"false", Bool, "false"},
		{"1.0", Float, "1.0000000000000000e+00"},
		{"3.1415", Float, "3.1415000000000002e+00"},
		{"-0.0", Float, "-0.0000000000000000e+00"},
		{"0e0", Float, "0.0000000000000000e+00"},
		{"0e00", Float, "0.0000000000000000e+00"},
		{"1e308", Float, "1.0000000000000000e+308"},
		{"6.626e-34", Float, "6.6259999999999998e-34"},
		{"5e-324", Float, "4.9406564584124654e-324"},
		{"1_0.2_5e1_0", Float, "1.0250000000000000e+11"},
		{"1e400", Float, "inf"},
		{"-1e400", Float, "-inf"},
		{"1e-400", Float, "0.0000000000000000e+00"},
		{"inf", Float, "inf"},
		{"+inf", Float, "inf"},
		{"-inf", Float, "-inf"},
		{"nan", Float, "nan"},
		{"-nan", Float, "nan"},
		{"1979-05-27", DateLocal, "1979-05-27"},
		{"2024-02-29", DateLocal, "2024-02-29"},
		{"07:32:00", TimeLocal, "07:32:00"},
		{"07:32:00.500", TimeLocal, "07:32:00.5"},
		{"07:32:00.000", TimeLocal, "07:32:00"},
		{"1979-05-27T07:32:00", DateTimeLocal, "1979-05-27T07:32:00"},
		{"1979-05-27t07:32:00.600", DateTimeLocal, "1979-05-27T07:32:00.6"},
		{"1979-05-27 07:32:00", DateTimeLocal, "1979-05-27T07:32:00"},
		{"1987-07-05 17:45:00z", DateTime, "1987-07-05T17:45:00Z"},
		{"1979-05-27T07:32:00-00:00", DateTime, "1979-05-27T07:32:00Z"},
		{"1979-05-27T07:32:00+00:00", DateTime, "1979-05-27T07:32:00Z"},
		{"1987-07-05T17:45:56.600+08:00", DateTime, "1987-07-05T17:45:56.6+08:00"},
		{"1979-05-27T00:32:00.999999999999-07:00", DateTime, "1979-05-27T00:32:00.999999999999-07:00"},
	}
	for _, tc := range tests {
		t.Run(tc.in, func(t *testing.T) {
			tbl, err := Parse([]byte("a = " + tc.in))
			if err != nil {
				t.Fatal(err)
			}
			n, _ := tbl.Get("a")
			v, ok := n.(*Value)
			if !ok {
				t.Fatalf("not a value: %#v", n)
			}
			if v.Type != tc.typ || v.Text != tc.want {
				t.Errorf("got %s %q, want %s %q", v.Type, v.Text, tc.typ, tc.want)
			}
		})
	}
}

func TestDateFollowedByComment(t *testing.T) {
	got := decode(t, "d = 1979-05-27 # comment")
	if want := `{"d":{"type":"date-local","value":"1979-05-27"}}`; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}
