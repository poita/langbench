// Package testrepo builds small git repositories on disk for tests, using only
// the standard library (including compress/zlib, which the production code
// deliberately avoids).
package testrepo

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"gitrepo/object"
)

// Repo is a repository under construction in a temporary directory.
type Repo struct {
	t   testing.TB
	Dir string
}

// New creates an empty repository directory.
func New(t testing.TB) *Repo {
	t.Helper()
	r := &Repo{t: t, Dir: t.TempDir()}
	r.Write("HEAD", "ref: refs/heads/main\n")
	if err := os.MkdirAll(filepath.Join(r.Dir, "objects", "pack"), 0o755); err != nil {
		t.Fatal(err)
	}
	return r
}

// Write writes a file relative to the repository root.
func (r *Repo) Write(rel, content string) {
	r.t.Helper()
	p := filepath.Join(r.Dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// Deflate compresses b into a zlib stream.
func Deflate(b []byte) []byte {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

// Stored returns the stored form "<type> <size>\0<payload>" of an object.
func Stored(t object.Type, data []byte) []byte {
	return append([]byte(fmt.Sprintf("%s %d\x00", t, len(data))), data...)
}

// Loose writes an object as a loose file and returns its id.
func (r *Repo) Loose(t object.Type, data []byte) object.ID {
	r.t.Helper()
	id := object.Hash(t, data)
	r.LooseRaw(id, Deflate(Stored(t, data)))
	return id
}

// LooseRaw writes raw bytes as the loose file for id.
func (r *Repo) LooseRaw(id object.ID, raw []byte) {
	r.t.Helper()
	h := id.String()
	r.Write(filepath.Join("objects", h[:2], h[2:]), string(raw))
}

// Blob writes a loose blob.
func (r *Repo) Blob(s string) object.ID { return r.Loose(object.Blob, []byte(s)) }

// Entry is a tree entry to be written by Tree.
type Entry struct {
	Mode uint32
	Name string
	ID   object.ID
}

// TreeData serialises entries in the order given.
func TreeData(entries ...Entry) []byte {
	var b []byte
	for _, e := range entries {
		b = append(b, fmt.Sprintf("%o %s\x00", e.Mode, e.Name)...)
		b = append(b, e.ID[:]...)
	}
	return b
}

// Tree writes a loose tree.
func (r *Repo) Tree(entries ...Entry) object.ID {
	return r.Loose(object.Tree, TreeData(entries...))
}

// CommitData serialises a commit.
func CommitData(tree object.ID, parents []object.ID, author string, committerTime int64, msg string) []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "tree %s\n", tree)
	for _, p := range parents {
		fmt.Fprintf(&b, "parent %s\n", p)
	}
	fmt.Fprintf(&b, "author %s <a@example.com> %d +0000\n", author, committerTime)
	fmt.Fprintf(&b, "committer %s <a@example.com> %d +0000\n\n%s", author, committerTime, msg)
	return b.Bytes()
}

// Commit writes a loose commit whose author and committer times are both ts.
func (r *Repo) Commit(tree object.ID, parents []object.ID, ts int64, msg string) object.ID {
	return r.Loose(object.Commit, CommitData(tree, parents, "Ada", ts, msg))
}

// Tag writes a loose annotated tag.
func (r *Repo) Tag(target object.ID, typ, name string) object.ID {
	return r.Loose(object.Tag, []byte(fmt.Sprintf("object %s\ntype %s\ntag %s\ntagger T <t@example.com> 1 +0000\n\nmsg\n", target, typ, name)))
}

// SetRef writes a loose ref holding id.
func (r *Repo) SetRef(name string, id object.ID) { r.Write(name, id.String()+"\n") }

// PackObj describes one object to put in a pack.
type PackObj struct {
	Type    object.Type // for a full object
	Data    []byte      // payload (full object) or delta stream
	OfsBase int         // for OFS_DELTA: index of the base in the list, or -1
	RefBase *object.ID  // for REF_DELTA: id of the base
}

// Full is a non-delta pack entry.
func Full(t object.Type, data []byte) PackObj { return PackObj{Type: t, Data: data, OfsBase: -1} }

// OfsDelta is an OFS_DELTA entry against list entry base.
func OfsDelta(base int, delta []byte) PackObj { return PackObj{Data: delta, OfsBase: base} }

// RefDelta is a REF_DELTA entry against the object id base.
func RefDelta(base object.ID, delta []byte) PackObj {
	return PackObj{Data: delta, OfsBase: -1, RefBase: &base}
}

// MakeDelta builds a delta that turns base into target: it copies the common
// prefix and inserts the rest.
func MakeDelta(base, target []byte) []byte {
	var d []byte
	d = appendVarint(d, uint64(len(base)))
	d = appendVarint(d, uint64(len(target)))
	n := 0
	for n < len(base) && n < len(target) && base[n] == target[n] {
		n++
	}
	if n > 0 {
		// copy offset 0, size n (n < 1<<24)
		op := byte(0x80)
		var args []byte
		for i := 0; i < 3; i++ {
			if b := byte(n >> (8 * i)); b != 0 {
				op |= 0x10 << i
				args = append(args, b)
			}
		}
		d = append(d, op)
		d = append(d, args...)
	}
	rest := target[n:]
	for len(rest) > 0 {
		k := len(rest)
		if k > 127 {
			k = 127
		}
		d = append(d, byte(k))
		d = append(d, rest[:k]...)
		rest = rest[k:]
	}
	return d
}

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

// WritePack writes objs as pack "name" with a matching index. ids must give
// the id of every entry, in the same order (computed by the caller because
// deltas need their reconstructed content hashed).
func (r *Repo) WritePack(name string, objs []PackObj, ids []object.ID) {
	r.t.Helper()
	pack := []byte("PACK\x00\x00\x00\x02")
	pack = binary.BigEndian.AppendUint32(pack, uint32(len(objs)))
	offs := make([]int, len(objs))
	for i, o := range objs {
		offs[i] = len(pack)
		typ := int(o.Type)
		switch {
		case o.OfsBase >= 0:
			typ = 6
		case o.RefBase != nil:
			typ = 7
		}
		size := len(o.Data)
		b := byte(typ<<4) | byte(size&15)
		size >>= 4
		for size > 0 {
			pack = append(pack, b|0x80)
			b = byte(size & 0x7f)
			size >>= 7
		}
		pack = append(pack, b)
		if typ == 6 {
			dist := offs[i] - offs[o.OfsBase]
			enc := []byte{byte(dist & 0x7f)}
			for dist >>= 7; dist > 0; dist >>= 7 {
				dist--
				enc = append([]byte{byte(dist&0x7f) | 0x80}, enc...)
			}
			pack = append(pack, enc...)
		} else if typ == 7 {
			pack = append(pack, o.RefBase[:]...)
		}
		pack = append(pack, Deflate(o.Data)...)
	}
	pack = append(pack, make([]byte, 20)...)

	order := make([]int, len(ids))
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(a, b int) bool { return bytes.Compare(ids[order[a]][:], ids[order[b]][:]) < 0 })
	idx := []byte("\xfftOc\x00\x00\x00\x02")
	var fan [256]uint32
	for _, id := range ids {
		for b := int(id[0]); b < 256; b++ {
			fan[b]++
		}
	}
	for _, f := range fan {
		idx = binary.BigEndian.AppendUint32(idx, f)
	}
	for _, i := range order {
		idx = append(idx, ids[i][:]...)
	}
	idx = append(idx, make([]byte, 4*len(ids))...) // CRCs, unchecked
	for _, i := range order {
		idx = binary.BigEndian.AppendUint32(idx, uint32(offs[i]))
	}
	idx = append(idx, make([]byte, 40)...)
	r.Write("objects/pack/"+name+".pack", string(pack))
	r.Write("objects/pack/"+name+".idx", string(idx))
}
