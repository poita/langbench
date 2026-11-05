package gitrepo

import (
	"errors"
	"fmt"
	"strings"
)

// ErrCommand is returned for unknown commands and wrong argument counts.
var ErrCommand = errors.New("gitrepo: invalid command")

// Execute runs one query line and returns its complete output. The line is
// split on single spaces (so empty tokens, from doubled or trailing spaces,
// make the command invalid). The supported commands are:
//
//	log <rev> [<n>]
//	ls-tree <rev> [<path>]
//	cat-file <rev>
//	diff <rev1> <rev2>
//	rev-parse <rev>
//	count-objects
//
// On failure the returned output is nil and err says why.
func (r *Repository) Execute(line string) ([]byte, error) {
	f := strings.Split(line, " ")
	args := f[1:]
	switch f[0] {
	case "log":
		if len(args) < 1 || len(args) > 2 {
			break
		}
		return r.cmdLog(args)
	case "ls-tree":
		if len(args) < 1 || len(args) > 2 {
			break
		}
		return r.cmdLsTree(args)
	case "cat-file":
		if len(args) != 1 {
			break
		}
		return r.cmdCatFile(args[0])
	case "diff":
		if len(args) != 2 {
			break
		}
		return r.cmdDiff(args[0], args[1])
	case "rev-parse":
		if len(args) != 1 {
			break
		}
		id, err := r.ResolveRevision(args[0])
		if err != nil {
			return nil, err
		}
		return append(id.appendHex(nil), '\n'), nil
	case "count-objects":
		if len(args) != 0 {
			break
		}
		loose, inPack, packs := r.Counts()
		return []byte(fmt.Sprintf("loose: %d\nin-pack: %d\npacks: %d\n", loose, inPack, packs)), nil
	}
	return nil, fmt.Errorf("%w: %q", ErrCommand, line)
}

func (r *Repository) cmdLog(args []string) ([]byte, error) {
	limit := -1
	if len(args) == 2 {
		s := args[1]
		if s == "" {
			return nil, ErrCommand
		}
		n := 0
		for i := 0; i < len(s); i++ {
			if s[i] < '0' || s[i] > '9' {
				return nil, ErrCommand
			}
			if n < 1<<40 {
				n = n*10 + int(s[i]-'0')
			}
		}
		limit = n
	}
	id, err := r.ResolveRevision(args[0])
	if err != nil {
		return nil, err
	}
	if id, err = r.Peel(id, TypeCommit); err != nil {
		return nil, err
	}
	out := []byte{}
	err = r.Walk(id, limit, func(id ID, c *Commit) {
		out = id.appendHex(out)
		out = append(out, ' ')
		out = append(out, c.LogSuffix...)
		out = append(out, '\n')
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (r *Repository) treeOf(rev string) (ID, error) {
	id, err := r.ResolveRevision(rev)
	if err != nil {
		return ID{}, err
	}
	return r.Peel(id, TypeTree)
}

func appendMode(dst []byte, m uint32) []byte {
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = '0' + byte(m&7)
		m >>= 3
	}
	return append(dst, b[:]...)
}

func (r *Repository) cmdLsTree(args []string) ([]byte, error) {
	tid, err := r.treeOf(args[0])
	if err != nil {
		return nil, err
	}
	if len(args) == 2 {
		if tid, err = r.LookupPath(tid, args[1]); err != nil {
			return nil, err
		}
	}
	t, err := r.Tree(tid)
	if err != nil {
		return nil, err
	}
	out := []byte{}
	for i := range t.Entries {
		e := &t.Entries[i]
		out = appendMode(out, e.Mode)
		out = append(out, ' ')
		out = append(out, e.Type().String()...)
		out = append(out, ' ')
		out = e.ID.appendHex(out)
		out = append(out, '\t')
		out = AppendQuoted(out, e.Name)
		out = append(out, '\n')
	}
	return out, nil
}

func (r *Repository) cmdCatFile(rev string) ([]byte, error) {
	id, err := r.ResolveRevision(rev)
	if err != nil {
		return nil, err
	}
	t, data, err := r.VerifyObject(id)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(data)+32)
	out = append(out, t.String()...)
	out = append(out, ' ')
	out = appendUint(out, uint64(len(data)))
	out = append(out, '\n')
	return append(out, data...), nil
}

func (r *Repository) cmdDiff(rev1, rev2 string) ([]byte, error) {
	a, err := r.treeOf(rev1)
	if err != nil {
		return nil, err
	}
	b, err := r.treeOf(rev2)
	if err != nil {
		return nil, err
	}
	entries, err := r.DiffTrees(a, b)
	if err != nil {
		return nil, err
	}
	out := []byte{}
	for i := range entries {
		e := &entries[i]
		out = append(out, ':')
		out = appendMode(out, e.OldMode)
		out = append(out, ' ')
		out = appendMode(out, e.NewMode)
		out = append(out, ' ')
		out = e.OldID.appendHex(out)
		out = append(out, ' ')
		out = e.NewID.appendHex(out)
		out = append(out, ' ', byte(e.Status), '\t')
		out = AppendQuoted(out, e.Path)
		out = append(out, '\n')
	}
	return out, nil
}
