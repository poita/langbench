package session_test

import (
	"fmt"

	"buildsys/session"
	"buildsys/vfs"
)

func Example() {
	fs := vfs.New()
	fs.Write("src/a.txt", []byte("abc\n"))
	fs.Write("main.kiln", []byte(`
step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
`))
	steps, err := session.Parse([]byte("build\nedit src/a.txt\nABC\n---\nbuild\n"))
	if err != nil {
		panic(err)
	}
	fmt.Print(string(session.Run(fs, steps)))
	out, _ := fs.Read("out/final.txt")
	fmt.Printf("%s", out)
	// Output:
	// step 1: build (default) -j 1
	//   run 0 2 w0 out/mid.txt upper()
	//   run 2 4 w0 out/final.txt number()
	//   ok ran=2 hit=0 time=4
	// step 2: edit src/a.txt
	//   ok size=4
	// step 3: build (default) -j 1
	//   run 0 2 w0 out/mid.txt upper()
	//   hit 2 out/final.txt
	//   ok ran=1 hit=1 time=2
	// 1: ABC
}
