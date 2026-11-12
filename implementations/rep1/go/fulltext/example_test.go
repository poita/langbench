package fulltext_test

import (
	"fmt"

	"fulltext"
)

func Example() {
	eng := fulltext.New([]fulltext.Document{
		{ID: "copy1", Text: "alpha beta gamma"},
		{ID: "copy2", Text: "alpha beta gamma"},
		{ID: "other", Text: "alpha alpha beta"},
	})
	for _, h := range eng.Search("alpha", 10) {
		fmt.Printf("%s\t%.4f\t%s\n", h.DocID, h.Score, h.Snippet)
	}
	fmt.Println(eng.Stats().Documents, "documents")
	// Output:
	// other	0.1836	alpha alpha beta
	// copy1	0.1335	alpha beta gamma
	// copy2	0.1335	alpha beta gamma
	// 3 documents
}
