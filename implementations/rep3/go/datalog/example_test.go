package datalog_test

import (
	"fmt"
	"os"

	"github.com/example/datalog"
)

func Example() {
	src := `
		parent(alice, bob). parent(bob, carol). parent(carol, dave).
		ancestor(X, Y) :- parent(X, Y).
		ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
		?- ancestor(alice, X).
	`
	prog, err := datalog.Parse([]byte(src))
	if err != nil {
		panic(err)
	}
	model, err := prog.Solve()
	if err != nil {
		panic(err)
	}
	datalog.WriteAnswers(os.Stdout, model.Answers())
	for _, t := range model.Relation("ancestor", 2)[:1] {
		fmt.Println(t[0], "->", t[1])
	}
	// Output:
	// ancestor(alice, bob)
	// ancestor(alice, carol)
	// ancestor(alice, dave)
	// -- 3
	// alice -> bob
}
