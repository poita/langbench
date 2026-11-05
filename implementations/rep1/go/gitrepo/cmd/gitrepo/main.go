// Command gitrepo answers a list of queries about a git repository.
//
// Usage:
//
//	gitrepo <input dir> <output dir>
//
// <input dir> holds repo/ (a git directory) and commands.txt (one query per
// line). For line k the answer is written to <output dir>/NNN.out; a failed
// query produces the single line "error".
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gitrepo"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: gitrepo <input dir> <output dir>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "gitrepo:", err)
		os.Exit(1)
	}
}

func run(in, out string) error {
	cmds, err := os.ReadFile(filepath.Join(in, "commands.txt"))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	repo, err := gitrepo.Open(filepath.Join(in, "repo"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "gitrepo: opening repository:", err)
		repo = nil // every query fails
	}
	lines := strings.Split(string(cmds), "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	for i, line := range lines {
		var res []byte
		if repo != nil {
			res, err = execute(repo, line)
		}
		if repo == nil || err != nil {
			res = []byte("error\n")
		}
		name := filepath.Join(out, fmt.Sprintf("%03d.out", i+1))
		if err := os.WriteFile(name, res, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// execute runs one query, turning any internal panic into a failure so that a
// single bad query can never take the program down.
func execute(repo *gitrepo.Repository, line string) (res []byte, err error) {
	defer func() {
		if p := recover(); p != nil {
			res, err = nil, fmt.Errorf("internal error: %v", p)
		}
	}()
	return repo.Execute(line)
}
