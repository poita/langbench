// Package query implements the textual command language of the gitrepo CLI on
// top of the gitrepo library: each command line is executed against a
// repository and yields the exact bytes of its answer.
//
// The commands are
//
//	log <rev> [<n>]
//	ls-tree <rev> [<path>]
//	cat-file <rev>
//	diff <rev1> <rev2>
//	rev-parse <rev>
//	count-objects
//
// A line is split into arguments on single spaces only, so doubled or trailing
// spaces produce empty arguments and make the command fail.
package query

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"gitrepo"
)

// ErrUsage is returned for an unknown command or the wrong arguments.
var ErrUsage = errors.New("usage error")

// ErrorOutput is what the CLI writes for a command that fails.
const ErrorOutput = "error\n"

// Execute runs one command line against r and returns its output. On any
// failure it returns a non-nil error and no output, never a partial answer.
func Execute(r *gitrepo.Repo, line string) (out []byte, err error) {
	defer func() {
		if p := recover(); p != nil {
			out, err = nil, fmt.Errorf("internal error: %v", p)
		}
	}()
	args := strings.Split(line, " ")
	switch args[0] {
	case "log":
		if len(args) != 2 && len(args) != 3 {
			return nil, ErrUsage
		}
		return log(r, args[1:])
	case "ls-tree":
		if len(args) != 2 && len(args) != 3 {
			return nil, ErrUsage
		}
		return lsTree(r, args[1:])
	case "cat-file":
		if len(args) != 2 {
			return nil, ErrUsage
		}
		return catFile(r, args[1])
	case "diff":
		if len(args) != 3 {
			return nil, ErrUsage
		}
		return diff(r, args[1], args[2])
	case "rev-parse":
		if len(args) != 2 {
			return nil, ErrUsage
		}
		id, err := r.RevParse(args[1])
		if err != nil {
			return nil, err
		}
		return []byte(id.String() + "\n"), nil
	case "count-objects":
		if len(args) != 1 {
			return nil, ErrUsage
		}
		c := r.CountObjects()
		return []byte(fmt.Sprintf("loose: %d\nin-pack: %d\npacks: %d\n", c.Loose, c.InPack, c.Packs)), nil
	}
	return nil, ErrUsage
}

func log(r *gitrepo.Repo, args []string) ([]byte, error) {
	limit := -1
	if len(args) == 2 {
		s := args[1]
		if s == "" {
			return nil, ErrUsage
		}
		for i := 0; i < len(s); i++ {
			if s[i] < '0' || s[i] > '9' {
				return nil, ErrUsage
			}
		}
		n, err := strconv.ParseUint(s, 10, 31)
		if err != nil {
			n = 1<<31 - 1 // more digits than any history is long
		}
		limit = int(n)
	}
	entries, err := r.Log(args[0], limit)
	if err != nil {
		return nil, err
	}
	var out []byte
	for _, e := range entries {
		out = append(out, e.ID.String()...)
		out = append(out, ' ')
		out = append(out, e.Author...)
		out = append(out, ' ')
		out = strconv.AppendUint(out, e.AuthorTime, 10)
		out = append(out, ' ')
		out = append(out, e.Subject...)
		out = append(out, '\n')
	}
	return out, nil
}

func lsTree(r *gitrepo.Repo, args []string) ([]byte, error) {
	path := ""
	if len(args) == 2 {
		path = args[1]
		if path == "" {
			return nil, ErrUsage
		}
	}
	entries, err := r.LsTree(args[0], path)
	if err != nil {
		return nil, err
	}
	var out []byte
	for _, e := range entries {
		out = fmt.Appendf(out, "%06o %s %s\t", e.Mode, e.Type(), e.ID)
		out = append(out, gitrepo.QuotePath(e.Name)...)
		out = append(out, '\n')
	}
	return out, nil
}

func catFile(r *gitrepo.Repo, rev string) ([]byte, error) {
	o, err := r.CatFile(rev)
	if err != nil {
		return nil, err
	}
	out := fmt.Appendf(nil, "%s %d\n", o.Type, len(o.Data))
	return append(out, o.Data...), nil
}

func diff(r *gitrepo.Repo, rev1, rev2 string) ([]byte, error) {
	entries, err := r.Diff(rev1, rev2)
	if err != nil {
		return nil, err
	}
	var out []byte
	for _, e := range entries {
		out = fmt.Appendf(out, ":%06o %06o %s %s %c\t", e.OldMode, e.NewMode, e.OldID, e.NewID, e.Status)
		out = append(out, gitrepo.QuotePath(e.Path)...)
		out = append(out, '\n')
	}
	return out, nil
}
