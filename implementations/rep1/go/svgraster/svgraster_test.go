package svgraster

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func pixel(img *Image, x, y int) [3]byte {
	i := (y*img.W + x) * 3
	return [3]byte{img.Pix[i], img.Pix[i+1], img.Pix[i+2]}
}

func mustRender(t *testing.T, svg string, w, h int) *Image {
	t.Helper()
	img, err := Render([]byte(svg), w, h)
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func TestFractionalRect(t *testing.T) { // SPEC 10.1
	img := mustRender(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4" width="8" height="4">
  <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/></svg>`, 8, 4)
	want := [][3]byte{{255, 255, 255}, {0, 0, 255}, {0, 0, 255}, {0, 0, 255}, {128, 128, 255}, {255, 255, 255}}
	for x, w := range want {
		if got := pixel(img, x, 1); got != w {
			t.Errorf("pixel %d = %v, want %v", x, got, w)
		}
	}
	if pixel(img, 4, 0) != [3]byte{255, 255, 255} || pixel(img, 4, 3) != [3]byte{255, 255, 255} {
		t.Error("rows 0 and 3 should be white")
	}
}

func TestScaledStroke(t *testing.T) { // SPEC 10.2
	img := mustRender(t, `<svg viewBox="0 0 10 10" width="10" height="10"><g transform="scale(2)">
  <rect x="1" y="1" width="3" height="3" fill="none" stroke="black" stroke-width="1"/></g></svg>`, 40, 40)
	black, white := [3]byte{}, [3]byte{255, 255, 255}
	checks := map[[2]int][3]byte{{3, 20}: white, {4, 20}: black, {11, 20}: black, {12, 20}: white,
		{27, 20}: white, {28, 20}: black, {35, 20}: black, {36, 20}: white, {20, 20}: white}
	for p, w := range checks {
		if got := pixel(img, p[0], p[1]); got != w {
			t.Errorf("pixel %v = %v, want %v", p, got, w)
		}
	}
}

func TestGroupOpacity(t *testing.T) { // SPEC 10.4
	svg := func(group, each string) string {
		return `<svg viewBox="0 0 50 40" width="50" height="40"><g` + group + `>
<circle cx="20" cy="20" r="15" fill="red"` + each + `/><circle cx="30" cy="20" r="15" fill="blue"` + each + `/></g></svg>`
	}
	g := pixel(mustRender(t, svg(` opacity="0.5"`, ""), 50, 40), 25, 20)
	if g != [3]byte{128, 128, 255} {
		t.Errorf("group opacity overlap = %v, want {128 128 255}", g)
	}
	e := pixel(mustRender(t, svg("", ` opacity="0.5"`), 50, 40), 25, 20)
	if e == g {
		t.Error("per-shape opacity should differ from group opacity")
	}
}

func TestInheritanceUseAndDisplay(t *testing.T) {
	img := mustRender(t, `<svg xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 4 2" width="4" height="2">
<defs><rect id="r" width="1" height="1"/></defs>
<g fill="lime"><use xlink:href="#r" x="1"/><use href="#r" x="2" fill="red" style="fill:blue"/>
<use href="#r" x="3" display="none"/><use href="#missing"/></g></svg>`, 4, 2)
	want := [][3]byte{{255, 255, 255}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}}
	for x, w := range want {
		if got := pixel(img, x, 0); got != w {
			t.Errorf("pixel %d = %v, want %v", x, got, w)
		}
	}
}

func TestViewportStretch(t *testing.T) {
	img := mustRender(t, `<svg viewBox="0 0 2 1"><rect width="1" height="1" fill="black"/></svg>`, 4, 4)
	if pixel(img, 1, 3) != ([3]byte{}) || pixel(img, 2, 3) != ([3]byte{255, 255, 255}) {
		t.Error("view box should be stretched to the output size")
	}
}

func TestRenderErrors(t *testing.T) {
	if _, err := Render([]byte("<svg/>"), 0, 5); err == nil {
		t.Error("expected size error")
	}
	if _, err := Render([]byte("nothing"), 5, 5); err == nil {
		t.Error("expected parse error")
	}
}

func TestParseJobs(t *testing.T) {
	jobs, err := ParseJobs("# c\r\n\n  a.svg 10 20\r\n\t# x\nb.svg  3\t4")
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 2 || jobs[0] != (Job{"a.svg", 10, 20}) || jobs[1] != (Job{"b.svg", 3, 4}) {
		t.Errorf("jobs = %+v", jobs)
	}
	if jobs[0].OutputName() != "a.ppm" {
		t.Errorf("OutputName = %q", jobs[0].OutputName())
	}
	for _, bad := range []string{"a.svg 1", "a.svg x 2", "a.svg 0 2", "a.svg 5000 2"} {
		if _, err := ParseJobs(bad); err == nil {
			t.Errorf("ParseJobs(%q) should fail", bad)
		}
	}
}

func TestRenderDir(t *testing.T) {
	in, out := t.TempDir(), filepath.Join(t.TempDir(), "sub", "out")
	os.WriteFile(filepath.Join(in, "a.svg"), []byte(`<svg width="2" height="1"><rect width="1" height="1" fill="#f00"/></svg>`), 0o644)
	os.WriteFile(filepath.Join(in, "render.txt"), []byte("a.svg 2 1\nmissing.svg 1 1\n"), 0o644)
	err := RenderDir(in, out)
	if err == nil || !strings.Contains(err.Error(), "missing.svg") {
		t.Errorf("err = %v, want a failure naming missing.svg", err)
	}
	got, rerr := os.ReadFile(filepath.Join(out, "a.ppm"))
	if rerr != nil {
		t.Fatal(rerr)
	}
	want := append([]byte("P6\n2 1\n255\n"), 255, 0, 0, 255, 255, 255)
	if !bytes.Equal(got, want) {
		t.Errorf("ppm = %q", got)
	}
}
