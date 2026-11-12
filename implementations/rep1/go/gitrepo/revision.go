package gitrepo

import (
	"errors"
	"fmt"
	"strings"

	"gitrepo/object"
	"gitrepo/odb"
)

// refPatterns are the places a bare name is looked up, in order.
var refPatterns = []string{
	"%s",
	"refs/%s",
	"refs/tags/%s",
	"refs/heads/%s",
	"refs/remotes/%s",
	"refs/remotes/%s/HEAD",
}

// RevParse resolves a revision expression to an object id. The syntax is
// git's: a ref name or abbreviated id, optionally followed by any number of
// "^", "^n", "~n" and "^{type}" suffixes. See the package documentation and
// SPEC.md for the exact rules. Only locating an object is attempted, so a
// damaged object resolves as long as it can be found.
func (r *Repo) RevParse(rev string) (object.ID, error) {
	var zero object.ID

	// Step 1: a "^{...}" suffix.
	if strings.HasSuffix(rev, "}") {
		if i := strings.LastIndex(rev, "^{"); i > 0 {
			base, err := r.RevParse(rev[:i])
			if err != nil {
				return zero, err
			}
			return r.peelSpec(base, rev[i+2:len(rev)-1])
		}
	}

	// Step 2: "^n" or "~n".
	j := len(rev)
	for j > 0 && rev[j-1] >= '0' && rev[j-1] <= '9' {
		j--
	}
	if j > 1 && (rev[j-1] == '^' || rev[j-1] == '~') {
		op := rev[j-1]
		n := uint64(1)
		if j < len(rev) {
			n = parseCount(rev[j:])
		}
		base, err := r.RevParse(rev[:j-1])
		if err != nil {
			return zero, err
		}
		id, err := r.peel(base, object.Commit)
		if err != nil {
			return zero, err
		}
		return r.ancestor(id, op, n)
	}

	// Step 3: a name.
	for _, pat := range refPatterns {
		if id, err := r.ReadRef(strings.ReplaceAll(pat, "%s", rev)); err == nil {
			return id, nil
		}
	}

	// Step 4: an object id or abbreviation.
	if len(rev) >= 4 && len(rev) <= 40 && isHex(rev) {
		lower := strings.ToLower(rev)
		if len(lower) == 40 {
			id, err := object.ParseID(lower)
			if err != nil {
				return zero, err
			}
			if !r.store.Has(id) {
				return zero, fmt.Errorf("%w: %s", odb.ErrNotFound, id)
			}
			return id, nil
		}
		return r.store.Abbrev(lower)
	}
	return zero, fmt.Errorf("cannot resolve revision %q", rev)
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

// parseCount parses a run of decimal digits, saturating instead of overflowing.
func parseCount(s string) uint64 {
	var n uint64
	for i := 0; i < len(s); i++ {
		d := uint64(s[i] - '0')
		if n > (1<<63-d)/10 {
			return 1 << 63
		}
		n = n*10 + d
	}
	return n
}

// ancestor applies "^n" or "~n" to a commit.
func (r *Repo) ancestor(id object.ID, op byte, n uint64) (object.ID, error) {
	if n == 0 {
		return id, nil
	}
	if op == '^' {
		c, err := r.commit(id)
		if err != nil {
			return id, err
		}
		if n > uint64(len(c.Parents)) {
			return id, fmt.Errorf("commit %s has no parent %d", id, n)
		}
		return c.Parents[n-1], nil
	}
	for ; n > 0; n-- {
		c, err := r.commit(id)
		if err != nil {
			return id, err
		}
		if len(c.Parents) == 0 {
			return id, fmt.Errorf("commit %s has no parent", id)
		}
		id = c.Parents[0]
	}
	return id, nil
}

// peelSpec applies the contents of a "^{...}" suffix.
func (r *Repo) peelSpec(id object.ID, spec string) (object.ID, error) {
	switch spec {
	case "":
		return r.peelTags(id)
	case "object":
		if !r.store.Has(id) {
			return id, fmt.Errorf("%w: %s", odb.ErrNotFound, id)
		}
		return id, nil
	case "commit":
		return r.peel(id, object.Commit)
	case "tree":
		return r.peel(id, object.Tree)
	case "blob":
		return r.peel(id, object.Blob)
	case "tag":
		return r.peel(id, object.Tag)
	}
	return id, fmt.Errorf("unknown peel %q", spec)
}

// peelTags implements "^{}": replace tag objects by their targets until the
// object is not a tag.
func (r *Repo) peelTags(id object.ID) (object.ID, error) {
	for {
		o, err := r.store.Read(id)
		if err != nil {
			return id, err
		}
		if o.Type != object.Tag {
			return id, nil
		}
		t, err := object.ParseTag(o.Data)
		if err != nil {
			return id, err
		}
		id = t.Target
	}
}

// peel implements "^{commit}", "^{tree}", "^{blob}" and "^{tag}": stop at an
// object of the wanted type, otherwise unwrap a tag to its target or a commit
// to its tree, and fail on anything else.
func (r *Repo) peel(id object.ID, want object.Type) (object.ID, error) {
	for {
		o, err := r.store.Read(id)
		if err != nil {
			return id, err
		}
		switch {
		case o.Type == want:
			return id, nil
		case o.Type == object.Tag:
			t, err := object.ParseTag(o.Data)
			if err != nil {
				return id, err
			}
			id = t.Target
		case o.Type == object.Commit:
			c, err := r.commit(id)
			if err != nil {
				return id, err
			}
			id = c.Tree
		default:
			return id, errors.New("cannot peel " + o.Type.String() + " to " + want.String())
		}
	}
}
