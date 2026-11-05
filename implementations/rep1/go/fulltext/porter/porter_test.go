package porter

import (
	"bufio"
	"os"
	"testing"
)

func TestStemExamples(t *testing.T) {
	cases := map[string]string{
		"caresses": "caress", "ponies": "poni", "ties": "ti", "caress": "caress", "cats": "cat",
		"feed": "feed", "agreed": "agre", "bleed": "bleed", "need": "need", "deed": "deed",
		"plastered": "plaster", "bled": "bled", "motoring": "motor", "sing": "sing",
		"conflated": "conflat", "troubled": "troubl", "sized": "size", "hopping": "hop",
		"tanned": "tan", "falling": "fall", "fizzed": "fizz", "filing": "file", "failing": "fail",
		"happy": "happi", "sky": "sky", "relational": "relat", "conditional": "condit",
		"digitizer": "digit", "vietnamization": "vietnam", "operator": "oper",
		"feudalism": "feudal", "decisiveness": "decis", "hopefulness": "hope",
		"callousness": "callous", "formaliti": "formal", "triplicate": "triplic",
		"formative": "form", "formalize": "formal", "electriciti": "electr",
		"electrical": "electr", "goodness": "good", "revival": "reviv",
		"allowance": "allow", "inference": "infer", "airliner": "airlin",
		"adjustable": "adjust", "defensible": "defens", "irritant": "irrit",
		"replacement": "replac", "adjustment": "adjust", "dependent": "depend",
		"adoption": "adopt", "communism": "commun", "activate": "activ",
		"effective": "effect", "bowdlerize": "bowdler", "probate": "probat",
		"rate": "rate", "cease": "ceas", "controll": "control", "roll": "roll",
		"running": "run", "runs": "run", "runner": "runner", "connection": "connect",
		"connections": "connect", "connecting": "connect", "dogs": "dog",
		"happiness": "happi", "happier": "happier", "relativity": "rel",
		"sensibility": "sensibl", "national": "nation", "controlled": "control",
		"abandoned": "abandon", "is": "is", "a": "a", "by": "by", "ion": "ion",
	}
	for in, want := range cases {
		if got := Stem(in); got != want {
			t.Errorf("Stem(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStemInPlaceDoesNotGrow(t *testing.T) {
	b := []byte("troubling")
	n := StemInPlace(b)
	if string(b[:n]) != "troubl" {
		t.Fatalf("got %q", b[:n])
	}
}

// TestPorterVocabulary checks Porter's published vocabulary when it is
// available (set PORTER_DIR to a directory holding voc.txt and output.txt).
func TestPorterVocabulary(t *testing.T) {
	dir := os.Getenv("PORTER_DIR")
	if dir == "" {
		t.Skip("PORTER_DIR not set")
	}
	in, err := os.Open(dir + "/voc.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.Open(dir + "/output.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	a, b := bufio.NewScanner(in), bufio.NewScanner(out)
	n := 0
	for a.Scan() {
		if !b.Scan() {
			t.Fatal("output.txt too short")
		}
		n++
		if got := Stem(a.Text()); got != b.Text() {
			t.Errorf("Stem(%q) = %q, want %q", a.Text(), got, b.Text())
		}
	}
	if n < 20000 {
		t.Fatalf("only %d words", n)
	}
}
