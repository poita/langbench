// Command gitrepo reads a git repository straight off disk and answers a list
// of queries about it.
//
// Usage:
//
//	gitrepo <input path> <output dir>
//
// <input path> is a directory holding repo/ (a .git directory or bare
// repository) and commands.txt (one query per line). For the command on line k
// the program writes <output dir>/NNN.out, where NNN is k zero-padded to at
// least three digits. A command that fails produces the file content "error".
// The exit status is 0 unless the arguments or output directory are unusable.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gitrepo"
	"gitrepo/query"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: gitrepo <input path> <output dir>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "gitrepo:", err)
		os.Exit(1)
	}
}

func run(input, outDir string) error {
	raw, err := os.ReadFile(filepath.Join(input, "commands.txt"))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	var lines []string
	if len(raw) > 0 {
		lines = strings.Split(string(raw), "\n")
		if lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
	}
	repo, repoErr := gitrepo.Open(filepath.Join(input, "repo"))
	if repoErr != nil {
		fmt.Fprintln(os.Stderr, "gitrepo: cannot open repository:", repoErr)
	}
	for i, line := range lines {
		out := []byte(query.ErrorOutput)
		if repoErr == nil {
			res, err := query.Execute(repo, line)
			if err == nil {
				out = res
			} else {
				fmt.Fprintf(os.Stderr, "%d: %s: %v\n", i+1, line, err)
			}
		}
		name := filepath.Join(outDir, fmt.Sprintf("%03d.out", i+1))
		if err := os.WriteFile(name, out, 0o644); err != nil {
			return err
		}
	}
	return nil
}
