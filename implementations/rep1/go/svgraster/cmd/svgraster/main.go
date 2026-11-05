// Command svgraster renders the SVG files listed in <input-dir>/render.txt
// to binary PPM files in <output-dir>.
//
// Usage:
//
//	svgraster <input-dir> <output-dir>
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"svgraster"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: svgraster <input-dir> <output-dir>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "svgraster:", err)
		os.Exit(1)
	}
}

func run(in, out string) error {
	list, err := os.ReadFile(filepath.Join(in, "render.txt"))
	if err != nil {
		return err
	}
	jobs, err := svgraster.ParseJobs(string(list))
	if err != nil {
		return fmt.Errorf("render.txt: %w", err)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	rr := svgraster.NewRenderer()
	failed := 0
	for _, j := range jobs {
		if err := renderOne(rr, in, out, j); err != nil {
			fmt.Fprintf(os.Stderr, "svgraster: %s: %v\n", j.Name, err)
			failed++
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d files failed", failed, len(jobs))
	}
	return nil
}

func renderOne(rr *svgraster.Renderer, in, out string, j svgraster.Job) error {
	data, err := os.ReadFile(filepath.Join(in, j.Name))
	if err != nil {
		return err
	}
	img, err := rr.Render(data, j.Width, j.Height)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, j.Output), img.PPM(), 0o644)
}
