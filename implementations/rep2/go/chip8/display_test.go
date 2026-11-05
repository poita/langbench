package chip8

import "testing"

func TestXORRowWrapAndCollision(t *testing.T) {
	var d Display
	if d.XORRow(5, 62, 0xF0) {
		t.Error("unexpected collision")
	}
	for x, want := range map[int]bool{62: true, 63: true, 0: true, 1: true, 2: false, 61: false} {
		if d.Pixel(x, 5) != want {
			t.Errorf("pixel %d: got %v want %v", x, !want, want)
		}
	}
	if !d.XORRow(5, 62, 0x80) || d.Pixel(62, 5) {
		t.Error("expected collision turning pixel 62 off")
	}
}

func TestSetPixelClear(t *testing.T) {
	var d Display
	d.SetPixel(10, 3, true)
	if !d.Pixel(10, 3) {
		t.Error("pixel not set")
	}
	d.SetPixel(10, 3, false)
	d.SetPixel(0, 0, true)
	d.Clear()
	if d != (Display{}) {
		t.Error("Clear left pixels")
	}
}
