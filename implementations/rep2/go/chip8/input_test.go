package chip8

import (
	"reflect"
	"testing"
)

func TestParseInput(t *testing.T) {
	p, err := ParseInput("60ff\n12\n0:0001 5:ffff\n")
	if err != nil {
		t.Fatal(err)
	}
	want := &Program{
		ROM:      []byte{0x60, 0xff},
		Cycles:   12,
		Schedule: KeySchedule{{0, 1}, {5, 0xffff}},
	}
	if !reflect.DeepEqual(p, want) {
		t.Fatalf("got %+v, want %+v", p, want)
	}
}

func TestParseInputOptionalParts(t *testing.T) {
	for _, in := range []string{"6001\n0", "6001\n0\n", "6001\n0\n\n"} {
		p, err := ParseInput(in)
		if err != nil {
			t.Fatalf("%q: %v", in, err)
		}
		if p.Cycles != 0 || len(p.Schedule) != 0 || len(p.ROM) != 2 {
			t.Fatalf("%q: %+v", in, p)
		}
	}
}

func TestParseInputErrors(t *testing.T) {
	for _, in := range []string{
		"", "6001", "zz\n1", "\n1", "6001\nx", "6001\n-1",
		"6001\n1\n0:1", "6001\n1\n3:0001 3:0002", "6001\n1\n3-0001",
	} {
		if _, err := ParseInput(in); err == nil {
			t.Errorf("%q: expected error", in)
		}
	}
}

func TestExecuteReportsROMTooLarge(t *testing.T) {
	p := &Program{ROM: make([]byte, MaxROMSize+1)}
	if _, err := p.Execute(); err == nil {
		t.Fatal("expected error")
	}
}

func TestReportExamples(t *testing.T) {
	blank := ""
	for i := 0; i < Height; i++ {
		blank += "................................................................\n"
	}
	tests := []struct{ name, in, want string }{
		{"example 1", "60ff7001610180141208\n6\n", blank +
			"PC=0208 I=0000 SP=0 DT=00 ST=00\n" +
			"V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"},
		{"example 3", "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n", blank +
			"PC=021e I=0000 SP=0 DT=07 ST=00\n" +
			"V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p, err := ParseInput(tc.in)
			if err != nil {
				t.Fatal(err)
			}
			m, err := p.Execute()
			if err != nil {
				t.Fatal(err)
			}
			if got := m.Report(); got != tc.want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestReportExample2(t *testing.T) {
	p, _ := ParseInput("6a3e6b1e6000f029dab5dab5\n5\n")
	m, err := p.Execute()
	if err != nil {
		t.Fatal(err)
	}
	got := m.Report()
	rows := []string{
		".#............................................................#.",
		".#............................................................#.",
		"##............................................................##",
	}
	for i, r := range rows {
		if got[i*65:i*65+64] != r {
			t.Fatalf("row %d = %q, want %q", i, got[i*65:i*65+64], r)
		}
	}
}
