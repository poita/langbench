package metric

import (
	"os"
	"strings"
	"testing"
)

func loadSet(t *testing.T) *Set {
	t.Helper()
	s, err := LoadSet(os.DirFS("../data"), "faces")
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestWidthSingleScale(t *testing.T) {
	serif := loadSet(t).ByName("serif")
	if w := serif.StringWidth("The", 10000); w != 15630 {
		t.Errorf("The = %d", w)
	}
	if w := serif.StringWidth("Tu", 10000); w != 10540 {
		t.Errorf("Tu = %d (kerns are summed before scaling)", w)
	}
	if w := serif.StringWidth("Tu", 11000); w != 11594 {
		t.Errorf("Tu@11000 = %d", w)
	}
}

func TestFaceResolution(t *testing.T) {
	cases := []struct {
		s    Style
		want string
	}{
		{Style{Serif, false, false}, "serif"},
		{Style{Serif, true, true}, "serif-bold-italic"},
		{Style{Sans, false, true}, "sans-italic"},
		{Style{Sans, true, false}, "sans-bold"},
		{Style{Mono, true, true}, "mono"},
	}
	set := loadSet(t)
	for _, c := range cases {
		if got := set.Face(c.s); got == nil || got.Name != c.want {
			t.Errorf("%+v -> %v, want %s", c.s, got, c.want)
		}
	}
}

func TestParseFace(t *testing.T) {
	f, err := ParseFace(strings.NewReader(`cfm 1
face x # comment
ascent 700
descent 200
space 250 100 50
extra 100
default 500
glyph 97 400
kern 97 97 -20
`))
	if err != nil {
		t.Fatal(err)
	}
	if f.Advance('a') != 400 || f.Advance('b') != 500 || f.Kern('a', 'a') != -20 || f.Space != 250 {
		t.Errorf("unexpected face %+v", f)
	}
	if _, err := ParseFace(strings.NewReader("bogus 1\n")); err == nil {
		t.Error("unknown record accepted")
	}
}
