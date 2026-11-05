package svgraster

import (
	"bytes"
	"testing"
)

func TestRenderAndPPM(t *testing.T) {
	img, err := Render([]byte(`<svg viewBox="0 0 8 4"><rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/></svg>`), 8, 4)
	if err != nil {
		t.Fatal(err)
	}
	ppm := img.PPM()
	hdr := []byte("P6\n8 4\n255\n")
	if !bytes.HasPrefix(ppm, hdr) || len(ppm) != len(hdr)+8*4*3 {
		t.Fatalf("bad ppm header/size: %q", ppm[:12])
	}
	row1 := ppm[len(hdr)+3*8 : len(hdr)+6*8]
	want := []byte{255, 255, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 128, 128, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}
	if !bytes.Equal(row1, want) {
		t.Errorf("row 1 = %v", row1)
	}
}

func TestRenderErrors(t *testing.T) {
	if _, err := Render([]byte(`<svg/>`), 0, 5); err == nil {
		t.Error("zero width accepted")
	}
	if _, err := Render([]byte(`garbage`), 5, 5); err == nil {
		t.Error("garbage accepted")
	}
	if _, err := Render([]byte(`<svg/><`), 5, 5); err != nil {
		t.Errorf("trailing junk after the document element should be ignored: %v", err)
	}
}

func TestParseJobs(t *testing.T) {
	jobs, err := ParseJobs("# c\n\n  \na.svg 10 20\r\n   b.svg\t3  4\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 2 || jobs[0] != (Job{"a.svg", 10, 20, "a.ppm"}) || jobs[1].Output != "b.ppm" || jobs[1].Height != 4 {
		t.Errorf("jobs = %+v", jobs)
	}
	for _, bad := range []string{"a.svg 1", "a.svg 0 5", "a.svg x 5", "a.txt 5 5", "../a.svg 5 5", "a.svg 5000 5"} {
		if _, err := ParseJobs(bad); err == nil {
			t.Errorf("ParseJobs(%q) succeeded", bad)
		}
	}
}
