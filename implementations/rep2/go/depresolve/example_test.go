package depresolve_test

import (
	"fmt"
	"strings"

	"github.com/example/depresolve"
)

func Example() {
	input := `a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
`
	problem, err := depresolve.Parse(strings.NewReader(input))
	if err != nil {
		panic(err)
	}
	res, err := problem.Resolve()
	if err != nil {
		panic(err)
	}
	for _, p := range res {
		fmt.Println(p.Name, p.Version)
	}
	// Output:
	// a 1.0.0
	// b 1.0.0
	// c 1.2.5
}

func ExampleRegistry_Resolve() {
	reg := depresolve.NewRegistry()
	reg.Add("lib", depresolve.MustParseVersion("1.0.0"), nil)
	reg.Add("lib", depresolve.MustParseVersion("2.0.0"), nil)
	root := []depresolve.Requirement{{Name: "lib", Range: depresolve.MustParseRange("^1.0.0")}}

	res, _ := reg.Resolve(root)
	fmt.Print(res)

	_, err := reg.Resolve([]depresolve.Requirement{{Name: "lib", Range: depresolve.MustParseRange(">=3.0.0")}})
	fmt.Println(err)
	// Output:
	// lib 1.0.0
	// depresolve: unsatisfiable
}
