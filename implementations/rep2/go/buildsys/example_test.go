package buildsys_test

import (
	"fmt"

	"buildsys"
	"buildsys/vfs"
)

// Build a two-step workspace on two workers, then rebuild it.
func ExampleBuild() {
	fs := vfs.New()
	fs.Write("main.kiln", `
step {
    out "out/a.txt"
    cmd write("A\n")
    cost 3
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd upper()
}
default "out/b.txt"
`)
	for i := 0; i < 2; i++ {
		res := buildsys.Build(fs, buildsys.Options{Workers: 2})
		fmt.Printf("ran=%d hit=%d time=%d err=%v\n", res.Ran, res.Hits, res.Time, res.Err)
	}
	fmt.Printf("%q\n", fs.Get("out/b.txt").Content())
	// Output:
	// ran=2 hit=0 time=5 err=<nil>
	// ran=0 hit=2 time=0 err=<nil>
	// "A\n"
}
