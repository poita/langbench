package gitrepo

import (
	"fmt"
	"strings"
)

// refPatterns are tried in order when a revision is a bare name.
var refPatterns = []string{
	"%s", "refs/%s", "refs/tags/%s", "refs/heads/%s", "refs/remotes/%s", "refs/remotes/%s/HEAD",
}

// ResolveRevision resolves a revision expression to an object id using
// git's rules: name lookup (HEAD, refs, tags, branches, remotes), abbreviated
// and full hexadecimal ids, the ^ and ~ parent operators and the ^{type}
// peel suffixes. Resolving only locates an object; content is read only as
// far as peeling and parent traversal require.
func (r *Repository) ResolveRevision(rev string) (ID, error) {
	// Rule 1: ^{...} suffix.
	if strings.HasSuffix(rev, "}") {
		if i := strings.LastIndex(rev, "^{"); i > 0 {
			id, err := r.ResolveRevision(rev[:i])
			if err != nil {
				return ID{}, err
			}
			return r.applyPeelSpec(id, rev[i+2:len(rev)-1])
		}
	}
	// Rule 2: ^n / ~n.
	j := len(rev)
	for j > 0 && rev[j-1] >= '0' && rev[j-1] <= '9' {
		j--
	}
	if j > 1 && (rev[j-1] == '^' || rev[j-1] == '~') {
		n := uint64(1)
		if j < len(rev) {
			n = 0
			for _, c := range []byte(rev[j:]) {
				if n > 1<<40 {
					break // saturate: no history is that deep
				}
				n = n*10 + uint64(c-'0')
			}
		}
		base, err := r.ResolveRevision(rev[:j-1])
		if err != nil {
			return ID{}, err
		}
		base, err = r.Peel(base, TypeCommit)
		if err != nil {
			return ID{}, err
		}
		return r.stepParents(base, rev[j-1] == '~', n)
	}
	// Rule 3: names.
	for _, pat := range refPatterns {
		name := strings.ReplaceAll(pat, "%s", rev)
		if id, ok := r.ResolveRef(name); ok {
			return id, nil
		}
	}
	// Rule 4: hexadecimal ids.
	if len(rev) >= 4 && len(rev) <= 40 && isHex(rev) {
		if len(rev) == 40 {
			id, _ := ParseID(rev)
			if r.HasObject(id) {
				return id, nil
			}
			return ID{}, fmt.Errorf("%w: %s", ErrNotFound, rev)
		}
		return r.Abbrev(rev)
	}
	return ID{}, fmt.Errorf("%w: %q", ErrRevision, rev)
}

func isHex(s string) bool {
	for i := 0; i < len(s); i++ {
		if hexVal(s[i]) < 0 {
			return false
		}
	}
	return true
}

func (r *Repository) stepParents(id ID, tilde bool, n uint64) (ID, error) {
	if n == 0 {
		return id, nil
	}
	if !tilde {
		c, err := r.Commit(id)
		if err != nil {
			return ID{}, err
		}
		if n > uint64(len(c.Parents)) {
			return ID{}, fmt.Errorf("%w: %s has no parent %d", ErrRevision, id, n)
		}
		return c.Parents[n-1], nil
	}
	for ; n > 0; n-- {
		c, err := r.Commit(id)
		if err != nil {
			return ID{}, err
		}
		if len(c.Parents) == 0 {
			return ID{}, fmt.Errorf("%w: %s has no parent", ErrRevision, id)
		}
		id = c.Parents[0]
	}
	return id, nil
}

func (r *Repository) applyPeelSpec(id ID, spec string) (ID, error) {
	switch spec {
	case "":
		return r.peelTags(id)
	case "commit":
		return r.Peel(id, TypeCommit)
	case "tree":
		return r.Peel(id, TypeTree)
	case "blob":
		return r.Peel(id, TypeBlob)
	case "tag":
		return r.Peel(id, TypeTag)
	case "object":
		if r.HasObject(id) {
			return id, nil
		}
		return ID{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return ID{}, fmt.Errorf("%w: unknown peel %q", ErrRevision, spec)
}

// peelTags dereferences tag objects until a non-tag is reached.
func (r *Repository) peelTags(id ID) (ID, error) {
	for {
		t, data, err := r.ReadObject(id)
		if err != nil {
			return ID{}, err
		}
		if t != TypeTag {
			return id, nil
		}
		if id, err = parseTagTarget(data); err != nil {
			return ID{}, err
		}
	}
}

// Peel dereferences id until it has the wanted type: tags are replaced by
// their target and commits by their tree. It fails if that never yields the
// wanted type.
func (r *Repository) Peel(id ID, want ObjectType) (ID, error) {
	for {
		t, data, err := r.ReadObject(id)
		if err != nil {
			return ID{}, err
		}
		if t == want {
			return id, nil
		}
		switch t {
		case TypeTag:
			if id, err = parseTagTarget(data); err != nil {
				return ID{}, err
			}
		case TypeCommit:
			c, err := r.Commit(id)
			if err != nil {
				return ID{}, err
			}
			if !c.HasTree {
				return ID{}, fmt.Errorf("%w: commit %s has no tree", ErrDamaged, id)
			}
			id = c.Tree
		default:
			return ID{}, fmt.Errorf("%w: cannot peel %s to %s", ErrType, t, want)
		}
	}
}
