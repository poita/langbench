package commonmark_test

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"

	"example.com/commonmark"
)

type specExample struct {
	N    int    `json:"n"`
	Sec  string `json:"sec"`
	MD   string `json:"md"`
	HTML string `json:"html"`
}

// TestSpecExamples runs the examples of the CommonMark specification that
// fall inside the supported subset (testdata/spec_examples.json).
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
		t.Run(strings.ReplaceAll(ex.Sec, " ", "_")+"/"+strconv.Itoa(ex.N), func(t *testing.T) {
			got := commonmark.ToHTMLString(ex.MD)
			if got != ex.HTML {
				t.Errorf("input:    %q\nwant:     %q\ngot:      %q", ex.MD, ex.HTML, got)
			}
		})
	}
}
