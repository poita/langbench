package metrics

import "testing"

const sample = `# test face
cfm 1
face serif
ascent 731
descent 223
space 254 127 85
extra 112
default 512
glyph 84 606   # T
glyph 104 509
glyph 117 508
kern 84 117 -60
`

func TestParseAndMeasure(t *testing.T) {
	f, err := Parse("serif", sample)
	if err != nil {
		t.Fatal(err)
	}
	if f.Ascent != 731 || f.Descent != 223 || f.Space != 254 || f.Stretch != 127 || f.Shrink != 85 || f.Extra != 112 {
		t.Errorf("bad vertical/glue metrics: %+v", f)
	}
	if f.Adv('T') != 606 || f.Adv('z') != 512 || f.Adv(0x10000) != 512 {
		t.Error("advance lookup or default wrong")
	}
	if f.Kern('T', 'u') != -60 || f.Kern('u', 'T') != 0 {
		t.Error("kern lookup wrong")
	}
	if got := f.Units([]rune("Tu")); got != 606+508-60 {
		t.Errorf("Units(Tu) = %d", got)
	}
}

func TestFaceIndex(t *testing.T) {
	cases := []struct {
		fam        int
		bold, ital bool
		want       string
	}{{Serif, false, false, "serif"}, {Serif, true, true, "serif-bold-italic"},
		{Sans, true, false, "sans-bold"}, {Sans, false, true, "sans-italic"}, {Mono, true, true, "mono"}}
	for _, c := range cases {
		if got := FaceNames[FaceIndex(c.fam, c.bold, c.ital)]; got != c.want {
			t.Errorf("FaceIndex = %s want %s", got, c.want)
		}
	}
}

func TestFields(t *testing.T) {
	if f := Fields("  glyph 1 2 # comment"); len(f) != 3 || f[0] != "glyph" {
		t.Errorf("Fields = %v", f)
	}
	if len(Fields("   # only comment")) != 0 {
		t.Error("comment line should be empty")
	}
}
