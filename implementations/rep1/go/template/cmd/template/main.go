// Command template renders a Jinja-style template.
//
// It reads a JSON context and named templates from standard input (see the
// README for the format), renders the first template and prints the result
// followed by a newline. A template failure prints a single line
// `error: <kind>` instead; in both cases the exit status is 0. Malformed
// input (not a template failure) is reported on stderr with status 2.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/template"
	"example.com/template/bundle"
	"example.com/template/jsonctx"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

// run is main without the process globals, so it can be tested.
func run(stdin io.Reader, stdout, stderr io.Writer) int {
	input, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(stderr, "template:", err)
		return 2
	}
	b, err := bundle.Parse(string(input))
	if err != nil {
		fmt.Fprintln(stderr, "template:", err)
		return 2
	}
	ctx, err := jsonctx.Parse(b.Context)
	if err != nil {
		fmt.Fprintln(stderr, "template:", err)
		return 2
	}
	env := template.NewEnvironment()
	for _, t := range b.Templates {
		env.Add(t.Name, t.Body)
	}
	out, err := env.Render(b.Templates[0].Name, ctx)
	if err != nil {
		if kind, ok := template.KindOf(err); ok {
			fmt.Fprintf(stdout, "error: %s\n", kind)
			fmt.Fprintln(stderr, err)
			return 0
		}
		fmt.Fprintln(stderr, "template:", err)
		return 2
	}
	io.WriteString(stdout, out)
	io.WriteString(stdout, "\n")
	return 0
}
