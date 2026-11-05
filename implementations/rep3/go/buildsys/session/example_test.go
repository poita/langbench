package session_test

import (
	"fmt"

	"buildsys/engine"
	"buildsys/session"
	"buildsys/vfs"
)

func Example() {
	fs := vfs.New()
	fs.Write("main.kiln", []byte(`
let names = ["a", "b"]
each n in names {
    step {
        out "out/{n}.txt"
        cmd write("{n}\n")
    }
}
step {
    out "out/all.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/all.txt"
`))

	// Run a single build directly...
	rep := engine.Build(fs, nil, 2)
	fmt.Println(rep.Err, rep.Ran, rep.Hits, rep.Time)

	// ...or drive a whole session and get the log text.
	log, _ := session.RunScript(fs, []byte("touch main.kiln\nbuild\n"))
	fmt.Print(string(log))

	out, _ := fs.Read("out/all.txt")
	fmt.Printf("%q\n", out)

	// Output:
	// <nil> 3 0 3
	// step 1: touch main.kiln
	//   ok
	// step 2: build (default) -j 1
	//   hit 0 out/a.txt
	//   hit 0 out/b.txt
	//   hit 0 out/all.txt
	//   ok ran=0 hit=3 time=0
	// "a\nb\n"
}
