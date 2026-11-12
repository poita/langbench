// Package depresolve is a deterministic package dependency resolver.
//
// Given a registry (every version of every package with its requirements) and
// a root manifest, it picks one version per needed package such that every
// requirement is satisfied, using a fully specified search: depth-first,
// newest version first, chronological backtracking. The first solution found
// is the answer, so every run (and every conforming implementation) agrees.
//
// The functionality is split over three subpackages:
//
//   - depresolve/semver: versions and ranges (*, exact, ^, ~, comparators)
//   - depresolve/registry: the registry model and its text format parser
//   - depresolve/resolve: the search itself
//
// This package ties them together with the text-in, text-out entry points
// used by the command-line tool.
package depresolve

import (
	"errors"
	"io"

	"depresolve/registry"
	"depresolve/resolve"
)

// Unsatisfiable is the line printed when no resolution exists.
const Unsatisfiable = "unsatisfiable"

// Solve parses the textual problem description from r and resolves it. It
// returns resolve.ErrUnsatisfiable if no resolution exists.
func Solve(r io.Reader) (resolve.Resolution, error) {
	in, err := registry.Parse(r)
	if err != nil {
		return nil, err
	}
	return resolve.Resolve(in.Registry, in.Root)
}

// Run solves the problem read from r and writes the result to w in the
// command-line output format: one "name version" line per chosen package, or
// the single line "unsatisfiable". Only malformed input yields an error.
func Run(r io.Reader, w io.Writer) error {
	res, err := Solve(r)
	if errors.Is(err, resolve.ErrUnsatisfiable) {
		_, err = io.WriteString(w, Unsatisfiable+"\n")
		return err
	}
	if err != nil {
		return err
	}
	buf := make([]byte, 0, 32*len(res))
	for _, p := range res {
		buf = append(buf, p.Package...)
		buf = append(buf, ' ')
		buf = append(buf, p.Version.String()...)
		buf = append(buf, '\n')
	}
	_, err = w.Write(buf)
	return err
}
