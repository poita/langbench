package textbuffer_test

import (
	"fmt"

	"textbuffer"
)

func Example() {
	b := textbuffer.New("alpha\nbeta\ngamma")

	// Three cursors, one at the start of each line.
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.Insert("- ")
	fmt.Printf("%q\n", b.Text())

	// Select to the end of every line and replace the selections.
	b.Move(textbuffer.End, true)
	b.Insert("X")
	fmt.Printf("%q\n", b.Text())

	// One undo reverts the whole multi-cursor edit.
	b.Undo()
	fmt.Printf("%q\n", b.Text())
	for _, c := range b.Cursors() {
		fmt.Println(c.Head.Line, c.Head.Col, c.Selected)
	}
	// Output:
	// "- alpha\n- beta\n- gamma"
	// "- X\n- X\n- X"
	// "- alpha\n- beta\n- gamma"
	// 0 7 true
	// 1 6 true
	// 2 7 true
}
