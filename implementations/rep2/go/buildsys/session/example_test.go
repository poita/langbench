package session_test

import (
	"fmt"

	"kiln/session"
	"kiln/vfs"
)

// Run a two-step build and a second, fully cached build in memory.
func Example() {
	fs := vfs.New()
	fs.Write("main.kiln", []byte(`
step {
    out "out/greeting.txt"
    cmd write("hello\n")
}
step {
    out "out/loud.txt"
    in "out/greeting.txt"
    cmd upper()
}
default "out/loud.txt"
`))

	script, err := session.Parse([]byte("build -j 2\nbuild\n"))
	if err != nil {
		panic(err)
	}
	fmt.Print(script.Run(fs))

	out, _ := fs.Read("out/loud.txt")
	fmt.Printf("%q\n", out)

	// Output:
	// step 1: build (default) -j 2
	//   run 0 1 w0 out/greeting.txt write("hello\n")
	//   run 1 3 w0 out/loud.txt upper()
	//   ok ran=2 hit=0 time=3
	// step 2: build (default) -j 1
	//   hit 0 out/greeting.txt
	//   hit 0 out/loud.txt
	//   ok ran=0 hit=2 time=0
	// "HELLO\n"
}
