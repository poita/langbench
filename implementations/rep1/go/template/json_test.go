package template

import "testing"

func TestParseJSON(t *testing.T) {
	v, err := ParseJSON([]byte(` {"b": 1, "a": [1.0, 2e2, -0, "xé\n😀", true, false, null], "c": {}} `))
	if err != nil {
		t.Fatal(err)
	}
	d := v.(*Dict)
	if got := d.Keys(); len(got) != 3 || got[0] != "b" || got[1] != "a" || got[2] != "c" {
		t.Fatalf("keys = %v", got)
	}
	a, _ := d.Get("a")
	items := a.(*List).Items
	if _, ok := items[0].(float64); !ok {
		t.Errorf("1.0 should be float, got %T", items[0])
	}
	if _, ok := items[1].(float64); !ok {
		t.Errorf("2e2 should be float, got %T", items[1])
	}
	if n, ok := items[2].(int64); !ok || n != 0 {
		t.Errorf("-0 should be integer 0, got %#v", items[2])
	}
	if items[3] != "xé\n\U0001F600" {
		t.Errorf("string = %q", items[3])
	}
	if items[4] != true || items[5] != false || items[6] != None {
		t.Errorf("literals = %v", items[4:])
	}
}

func TestParseJSONErrors(t *testing.T) {
	for _, s := range []string{"", "{", `{"a":}`, `{"a" 1}`, "[1,]", "01", "1.", `"abc`, `{"a":1} x`, "tru", `"\x"`, "\"a\nb\""} {
		if _, err := ParseJSON([]byte(s)); err == nil {
			t.Errorf("ParseJSON(%q) succeeded", s)
		}
	}
}

func TestDictIndex(t *testing.T) {
	d := NewDict(0)
	for i := 0; i < 50; i++ {
		d.Set(string(rune('a'+i%26))+string(rune('a'+i/26)), int64(i))
	}
	if d.Len() != 50 {
		t.Fatalf("len = %d", d.Len())
	}
	d.Set("aa", int64(100))
	if v, _ := d.Get("aa"); v != int64(100) || d.Len() != 50 {
		t.Fatalf("replace failed: %v len %d", v, d.Len())
	}
	if _, ok := d.Get("zz"); ok {
		t.Fatal("unexpected key")
	}
}
