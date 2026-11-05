package datalog_test

import (
	"fmt"
	"os"

	"github.com/example/datalog"
)

func ExampleSolveString() {
	out, err := datalog.SolveString(`
		edge(1, 2). edge(2, 3).
		path(X, Y) :- edge(X, Y).
		path(X, Z) :- edge(X, Y), path(Y, Z).
		?- path(1, X).`)
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Print(out)
	// Output:
	// path(1, 2)
	// path(1, 3)
	// -- 2
}

func ExampleModel_Relation() {
	prog, _ := datalog.Parse([]byte(`
		parent(tom, bob). parent(bob, ann).
		grand(X, Z) :- parent(X, Y), parent(Y, Z).`))
	model, err := datalog.Evaluate(prog)
	if err != nil {
		fmt.Println(err)
		return
	}
	for _, t := range model.Relation("grand", 2) {
		fmt.Println(t[0], t[1])
	}
	// Output: tom ann
}

func ExampleModel_WriteAnswers() {
	prog, _ := datalog.Parse([]byte(`n(1). n(b). n(a). ?- n(X).`))
	model, _ := datalog.Evaluate(prog)
	model.WriteAnswers(os.Stdout)
	// Output:
	// n(1)
	// n(a)
	// n(b)
	// -- 3
}
