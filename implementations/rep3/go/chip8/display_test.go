package chip8

import "testing"

func TestXORRowWrapAndCollision(t *testing.T) {
	var d Display
	if d.XORRow(62, 31, 0xF0) {
		t.Fatal("unexpected collision")
	}
	for _, x := range []int{62, 63, 0, 1} {
		if !d.Pixel(x, 31) {
			t.Errorf("pixel %d not set", x)
		}
	}
	if d.Pixel(2, 31) || d.Pixel(61, 31) {
		t.Error("extra pixels set")
	}
	if !d.XORRow(62, 31, 0xF0) || d != (Display{}) {
		t.Error("second XOR should collide and clear")
	}
}

func TestXORRowZeroOffset(t *testing.T) {
	var d Display
	d.XORRow(0, 0, 0x80)
	if !d.Pixel(0, 0) || d.Pixel(1, 0) || d[0] != 1<<63 {
		t.Errorf("row=%x", d[0])
	}
}

func TestSetPixelAndClear(t *testing.T) {
	var d Display
	d.SetPixel(5, 6, true)
	if !d.Pixel(5, 6) {
		t.Fatal("not set")
	}
	d.SetPixel(5, 6, false)
	if d.Pixel(5, 6) {
		t.Fatal("not cleared")
	}
	d.SetPixel(1, 1, true)
	d.Clear()
	if d != (Display{}) {
		t.Fatal("Clear failed")
	}
}
