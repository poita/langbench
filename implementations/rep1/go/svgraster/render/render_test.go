package render

import (
	"testing"

	"svgraster/xmlmini"
)

func draw(t *testing.T, src string, w, h int) []byte {
	t.Helper()
	root, err := xmlmini.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	c, err := New().Render(root, w, h)
	if err != nil {
		t.Fatal(err)
	}
	return c.RGB()
}

func px(img []byte, w, x, y int) [3]byte {
	i := 3 * (y*w + x)
	return [3]byte{img[i], img[i+1], img[i+2]}
}

var (
	white = [3]byte{255, 255, 255}
	black = [3]byte{0, 0, 0}
	red   = [3]byte{255, 0, 0}
	blue  = [3]byte{0, 0, 255}
)

func TestFillAndViewBoxScaling(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 4 4"><rect x="1" y="1" width="2" height="2" fill="#f00"/></svg>`, 8, 8)
	if px(img, 8, 4, 4) != red || px(img, 8, 1, 1) != white || px(img, 8, 2, 2) != red || px(img, 8, 5, 5) != red || px(img, 8, 6, 6) != white {
		t.Error("viewBox scaling wrong")
	}
}

func TestInheritanceAndStylePrecedence(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 3 1">
	  <g fill="red" style="fill:blue">
	    <rect x="0" width="1" height="1"/>
	    <rect x="1" width="1" height="1" fill="red"/>
	    <rect x="2" width="1" height="1" style="fill:;" fill="#000"/>
	  </g></svg>`, 3, 1)
	if px(img, 3, 0, 0) != blue {
		t.Errorf("style must beat attribute: %v", px(img, 3, 0, 0))
	}
	if px(img, 3, 1, 0) != red {
		t.Errorf("own attribute must beat inherited: %v", px(img, 3, 1, 0))
	}
	if px(img, 3, 2, 0) != black {
		t.Errorf("empty style value must fall back to the attribute: %v", px(img, 3, 2, 0))
	}
}

func TestDisplayNone(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 2 1">
	  <g display="none"><rect width="1" height="1" display="inline"/></g>
	  <rect x="1" width="1" height="1" display="none" style="display:inline"/></svg>`, 2, 1)
	if px(img, 2, 0, 0) != white || px(img, 2, 1, 0) != black {
		t.Error("display handling wrong")
	}
}

func TestUseInheritsAndTranslates(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 4 2" xmlns:xlink="x">
	  <defs><rect id="r" width="1" height="1"/></defs>
	  <use xlink:href="#r" x="2" y="1" fill="blue"/>
	  <use href="#missing"/></svg>`, 4, 2)
	if px(img, 4, 2, 1) != blue || px(img, 4, 0, 0) != white {
		t.Error("use wrong")
	}
}

func TestGroupOpacity(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 2 1"><g opacity="0.5">
	  <rect width="2" height="1" fill="red"/><rect width="2" height="1" fill="blue"/></g></svg>`, 2, 1)
	// 0.5*blue over white, not affected by the red underneath.
	if got := px(img, 2, 0, 0); got != [3]byte{128, 128, 255} {
		t.Errorf("got %v", got)
	}
}

func TestStrokeFrame(t *testing.T) {
	img := draw(t, `<svg viewBox="0 0 10 10"><g transform="scale(2)">
	  <rect x="1" y="1" width="3" height="3" fill="none" stroke="black"/></g></svg>`, 40, 40)
	if px(img, 40, 4, 20) != black || px(img, 40, 11, 20) != black || px(img, 40, 12, 20) != white || px(img, 40, 3, 20) != white {
		t.Error("stroke frame edges wrong")
	}
}

func TestFillRule(t *testing.T) {
	nz := draw(t, `<svg viewBox="0 0 20 20"><path d="M10 0 L16 18 L0 7 L20 7 L4 18 Z"/></svg>`, 20, 20)
	eo := draw(t, `<svg viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 0 L16 18 L0 7 L20 7 L4 18 Z"/></svg>`, 20, 20)
	if px(nz, 20, 10, 9) != black || px(eo, 20, 10, 9) != white {
		t.Error("centre pentagon should be filled for nonzero only")
	}
}

func TestNotSVG(t *testing.T) {
	root, _ := xmlmini.Parse([]byte(`<html/>`))
	if _, err := New().Render(root, 4, 4); err == nil {
		t.Error("expected error")
	}
}
