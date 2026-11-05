package typeinfer_test

import (
	"fmt"

	"example.com/typeinfer"
)

func Example() {
	results, err := typeinfer.Infer(`
let id x = x;;
let compose f g x = f (g x);;
(id 1, id true);;
fun f -> (f 1, f true);;
let oops = missing;;`)
	if err != nil {
		panic(err)
	}
	for _, r := range results {
		fmt.Println(r)
	}
	// Output:
	// id : 'a -> 'a
	// compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
	// - : int * bool
	// error: unify
	// error: unbound
}

func ExampleChecker_Check() {
	c := typeinfer.NewChecker()
	c.Check([]byte("let twice f x = f (f x);;"))
	results, _ := c.Check([]byte("twice (fun n -> n + 1);;"))
	fmt.Println(results[0])
	ty, _ := c.TypeOf("twice")
	fmt.Println(ty)
	// Output:
	// - : int -> int
	// ('a -> 'a) -> 'a -> 'a
}
