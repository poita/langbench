package commonmark_test

import (
	"encoding/json"
	"os"
	"testing"

	"example.com/commonmark"
)

type specExample struct {
	N        int    `json:"n"`
	Section  string `json:"sec"`
	Markdown string `json:"md"`
	HTML     string `json:"html"`
}

func TestSpecExamples(t *testing.T) {
	data, err := os.ReadFile("testdata/spec_examples.json")
	if err != nil {
		t.Fatal(err)
	}
	var examples []specExample
	if err := json.Unmarshal(data, &examples); err != nil {
		t.Fatal(err)
	}
	for _, ex := range examples {
		got := commonmark.ToHTML(ex.Markdown)
		if got != ex.HTML {
			t.Logf("FAIL %d (%s)\n--- md\n%q\n--- want\n%q\n--- got\n%q", ex.N, ex.Section, ex.Markdown, ex.HTML, got)
			t.Fail()
		}
	}
}
