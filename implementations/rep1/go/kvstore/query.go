package tessera

import (
	"bytes"
	"sort"

	"example.com/tessera/value"
)

// CmpOp is a comparison operator of a predicate.
type CmpOp uint8

// The six comparison operators.
const (
	OpEq CmpOp = iota
	OpNe
	OpLt
	OpLe
	OpGt
	OpGe
)

// String returns the operator as written in the command language.
func (o CmpOp) String() string {
	return [...]string{"==", "!=", "<", "<=", ">", ">="}[o]
}

// PredKind is the kind of node of a predicate tree.
type PredKind uint8

// The node kinds of a predicate tree.
const (
	PredCmp PredKind = iota
	PredExists
	PredMissing
	PredNot
	PredAnd
	PredOr
)

// Predicate is a node of a predicate tree (SPEC §17.1). Build one with the
// constructors Cmp, Exists, Missing, Not, And and Or.
type Predicate struct {
	Kind        PredKind
	Left, Right *Predicate // operands of And, Or (both) and Not (Left)
	Path        []string   // Cmp, Exists, Missing
	Op          CmpOp      // Cmp
	Value       value.Value
}

// Cmp builds the predicate "path op v".
func Cmp(path []string, op CmpOp, v value.Value) *Predicate {
	return &Predicate{Kind: PredCmp, Path: path, Op: op, Value: v}
}

// Exists builds "exists path".
func Exists(path []string) *Predicate { return &Predicate{Kind: PredExists, Path: path} }

// Missing builds "missing path".
func Missing(path []string) *Predicate { return &Predicate{Kind: PredMissing, Path: path} }

// Not builds "not(p)".
func Not(p *Predicate) *Predicate { return &Predicate{Kind: PredNot, Left: p} }

// And builds "a and b".
func And(a, b *Predicate) *Predicate { return &Predicate{Kind: PredAnd, Left: a, Right: b} }

// Or builds "a or b".
func Or(a, b *Predicate) *Predicate { return &Predicate{Kind: PredOr, Left: a, Right: b} }

// Eval reports whether doc satisfies the predicate (SPEC §17.2).
func (p *Predicate) Eval(doc value.Value) bool {
	switch p.Kind {
	case PredAnd:
		return p.Left.Eval(doc) && p.Right.Eval(doc)
	case PredOr:
		return p.Left.Eval(doc) || p.Right.Eval(doc)
	case PredNot:
		return !p.Left.Eval(doc)
	case PredExists:
		_, ok := doc.Lookup(p.Path)
		return ok
	case PredMissing:
		_, ok := doc.Lookup(p.Path)
		return !ok
	}
	x, ok := doc.Lookup(p.Path)
	if !ok {
		return false
	}
	switch p.Op {
	case OpEq:
		return value.Equal(x, p.Value)
	case OpNe:
		return !value.Equal(x, p.Value)
	}
	c, ok := value.Compare(x, p.Value)
	if !ok {
		return false
	}
	switch p.Op {
	case OpLt:
		return c < 0
	case OpLe:
		return c <= 0
	case OpGt:
		return c > 0
	default:
		return c >= 0
	}
}

// leaves flattens the top-level conjunction into its leaves, left to right.
func (p *Predicate) leaves(out []*Predicate) []*Predicate {
	if p.Kind == PredAnd {
		return p.Right.leaves(p.Left.leaves(out))
	}
	return append(out, p)
}

func pathText(segs []string) string {
	n := len(segs) - 1
	for _, s := range segs {
		n += len(s)
	}
	b := make([]byte, 0, n)
	for i, s := range segs {
		if i > 0 {
			b = append(b, '.')
		}
		b = append(b, s...)
	}
	return string(b)
}

// plan selects the access path for a predicate (SPEC §17.3). slot is -1 for a
// scan plan, otherwise the directory slot of the chosen index and leaf the
// comparison that selected it.
func (db *DB) plan(p *Predicate) (slot int, leaf *Predicate) {
	slot = -1
	var bestText string
	for _, l := range p.leaves(nil) {
		if l.Kind != PredCmp || l.Op == OpNe || l.Value.Kind >= value.List {
			continue
		}
		text := pathText(l.Path)
		s := -1
		for i := range db.hdr.slots {
			if db.hdr.slots[i].live && db.hdr.slots[i].path == text {
				s = i
				break
			}
		}
		if s < 0 {
			continue
		}
		better := false
		switch {
		case leaf == nil:
			better = true
		case (l.Op == OpEq) != (leaf.Op == OpEq):
			better = l.Op == OpEq
		case text < bestText:
			better = true
		}
		if better {
			slot, leaf, bestText = s, l, text
		}
	}
	return slot, leaf
}

// Plan returns the plan word a Find with this predicate would report:
// "scan" or "index <path>".
func (db *DB) Plan(p *Predicate) string {
	if slot, _ := db.plan(p); slot >= 0 {
		return "index " + db.hdr.slots[slot].path
	}
	return "scan"
}

// candidateKeys walks the candidate range of an index plan (SPEC §17.3) and
// returns the document keys of its entries.
func (db *DB) candidateKeys(slot int, op CmpOp, v value.Value) [][]byte {
	tr := db.indexTree(slot)
	V, _ := value.VKey(v)
	var keys [][]byte
	add := func(k []byte) { keys = append(keys, docKeyOf(k)) }
	switch op {
	case OpEq:
		tr.walkFrom(V, func(c *cell) bool {
			if !bytes.HasPrefix(c.key, V) {
				return false
			}
			add(c.key)
			return true
		})
	case OpLt, OpLe:
		tr.walkFrom(nil, func(c *cell) bool {
			if bytes.Compare(c.key, V) >= 0 && !(op == OpLe && bytes.HasPrefix(c.key, V)) {
				return false
			}
			add(c.key)
			return true
		})
	case OpGt:
		tr.walkFrom(V, func(c *cell) bool {
			if !bytes.HasPrefix(c.key, V) {
				add(c.key)
			}
			return true
		})
	case OpGe:
		tr.walkFrom(V, func(c *cell) bool {
			add(c.key)
			return true
		})
	}
	return keys
}

// Entry is one key/document pair returned by Scan and Find. Doc is the zero
// value (null) for a keys-only scan.
type Entry struct {
	Key []byte
	Doc value.Value
}

// Find returns the documents satisfying p in ascending key order, at most
// limit of them when limit >= 0, together with the plan used.
func (db *DB) Find(p *Predicate, limit int) (entries []Entry, plan string) {
	slot, leaf := db.plan(p)
	plan = "scan"
	if slot >= 0 {
		plan = "index " + db.hdr.slots[slot].path
	}
	if limit == 0 {
		return nil, plan
	}
	full := func() bool { return limit >= 0 && len(entries) >= limit }
	if slot < 0 {
		db.primary().walkFrom(nil, func(c *cell) bool {
			doc, err := value.Deserialize(db.readDoc(c))
			if err == nil && p.Eval(doc) {
				entries = append(entries, Entry{c.key, doc})
			}
			return !full()
		})
		return entries, plan
	}
	keys := db.candidateKeys(slot, leaf.Op, leaf.Value)
	sort.Slice(keys, func(i, j int) bool { return bytes.Compare(keys[i], keys[j]) < 0 })
	prim := db.primary()
	for _, k := range keys {
		c, ok := prim.find(k)
		if !ok {
			continue
		}
		doc, err := value.Deserialize(db.readDoc(&c))
		if err == nil && p.Eval(doc) {
			entries = append(entries, Entry{k, doc})
			if full() {
				break
			}
		}
	}
	return entries, plan
}
