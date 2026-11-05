package gitrepo

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"gitrepo/sha1"
)

// testRepo builds on-disk repositories for the tests.
type testRepo struct {
	t   *testing.T
	dir string
}

func newTestRepo(t *testing.T) *testRepo {
	dir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(dir, "objects"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &testRepo{t: t, dir: dir}
}

func (tr *testRepo) write(rel string, data []byte) {
	p := filepath.Join(tr.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		tr.t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		tr.t.Fatal(err)
	}
}

func zdeflate(data []byte) []byte {
	var b bytes.Buffer
	w := zlib.NewWriter(&b)
	w.Write(data)
	w.Close()
	return b.Bytes()
}

// loose stores an object as a loose file and returns its id.
func (tr *testRepo) loose(typ ObjectType, payload []byte) ID {
	id := HashObject(typ, payload)
	h := id.String()
	stored := append([]byte(fmt.Sprintf("%s %d\x00", typ, len(payload))), payload...)
	tr.write("objects/"+h[:2]+"/"+h[2:], zdeflate(stored))
	return id
}

func (tr *testRepo) ref(name, content string) { tr.write(name, []byte(content+"\n")) }

// treeEntry is a helper for building tree payloads.
type treeEntry struct {
	mode string
	name string
	id   ID
}

func treePayload(entries ...treeEntry) []byte {
	var b bytes.Buffer
	for _, e := range entries {
		b.WriteString(e.mode + " " + e.name + "\x00")
		b.Write(e.id[:])
	}
	return b.Bytes()
}

func (tr *testRepo) commit(tree ID, parents []ID, author string, atime, ctime int, msg string) ID {
	var b bytes.Buffer
	fmt.Fprintf(&b, "tree %s\n", tree)
	for _, p := range parents {
		fmt.Fprintf(&b, "parent %s\n", p)
	}
	fmt.Fprintf(&b, "author %s <a@example.com> %d +0000\n", author, atime)
	fmt.Fprintf(&b, "committer C <c@example.com> %d +0000\n\n%s", ctime, msg)
	return tr.loose(TypeCommit, b.Bytes())
}

// packObject describes one object to put in a pack.
type packObject struct {
	typ     int    // 1-4, 6 (ofs delta), 7 (ref delta)
	payload []byte // for 1-4: the data; for deltas: the raw delta
	baseIdx int    // ofs delta: index of the base within the pack
	baseID  ID     // ref delta: base id
	id      ID     // the id this object will be indexed under
}

func packHeader(typ int, size int) []byte {
	b := []byte{byte(typ<<4) | byte(size&15)}
	size >>= 4
	for size > 0 {
		b[len(b)-1] |= 0x80
		b = append(b, byte(size&0x7f))
		size >>= 7
	}
	return b
}

func ofsEncode(v int) []byte {
	out := []byte{byte(v & 0x7f)}
	for v >>= 7; v > 0; v >>= 7 {
		v--
		out = append([]byte{0x80 | byte(v&0x7f)}, out...)
	}
	return out
}

// writePack writes name.pack and name.idx for the objects.
func (tr *testRepo) writePack(name string, objs []packObject) {
	var pk bytes.Buffer
	pk.WriteString("PACK")
	binary.Write(&pk, binary.BigEndian, uint32(2))
	binary.Write(&pk, binary.BigEndian, uint32(len(objs)))
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = pk.Len()
		pk.Write(packHeader(o.typ, len(o.payload)))
		switch o.typ {
		case 6:
			pk.Write(ofsEncode(offsets[i] - offsets[o.baseIdx]))
		case 7:
			pk.Write(o.baseID[:])
		}
		pk.Write(zdeflate(o.payload))
	}
	sum := sha1.Sum(pk.Bytes())
	pk.Write(sum[:])

	order := make([]int, len(objs))
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(a, b int) bool { return bytes.Compare(objs[order[a]].id[:], objs[order[b]].id[:]) < 0 })
	var idx bytes.Buffer
	idx.Write([]byte{0xff, 't', 'O', 'c'})
	binary.Write(&idx, binary.BigEndian, uint32(2))
	var fan [256]uint32
	for _, o := range objs {
		fan[o.id[0]]++
	}
	for i := 1; i < 256; i++ {
		fan[i] += fan[i-1]
	}
	binary.Write(&idx, binary.BigEndian, fan)
	for _, i := range order {
		idx.Write(objs[i].id[:])
	}
	for range order {
		binary.Write(&idx, binary.BigEndian, uint32(0)) // CRCs are not checked
	}
	for _, i := range order {
		binary.Write(&idx, binary.BigEndian, uint32(offsets[i]))
	}
	idx.Write(sum[:])
	isum := sha1.Sum(idx.Bytes())
	idx.Write(isum[:])
	tr.write("objects/pack/"+name+".pack", pk.Bytes())
	tr.write("objects/pack/"+name+".idx", idx.Bytes())
}

// deltaInsert builds a delta that produces target from a base of baseLen
// bytes by copying base[:copyLen] and inserting the rest of target.
func deltaFor(baseLen int, target []byte, copyLen int) []byte {
	var d []byte
	varint := func(v int) {
		for {
			b := byte(v & 0x7f)
			v >>= 7
			if v > 0 {
				d = append(d, b|0x80)
			} else {
				d = append(d, b)
				return
			}
		}
	}
	varint(baseLen)
	varint(len(target))
	if copyLen > 0 {
		// copy offset 0 (no offset bytes), size in 1-2 bytes
		op := byte(0x80)
		var sz []byte
		if copyLen&0xff != 0 || copyLen > 0xffff {
			op |= 0x10
			sz = append(sz, byte(copyLen))
		}
		if copyLen>>8 != 0 {
			op |= 0x20
			sz = append(sz, byte(copyLen>>8))
		}
		d = append(d, op)
		d = append(d, sz...)
	}
	rest := target[copyLen:]
	for len(rest) > 0 {
		n := min(len(rest), 127)
		d = append(d, byte(n))
		d = append(d, rest[:n]...)
		rest = rest[n:]
	}
	return d
}

func mustOpen(t *testing.T, tr *testRepo) *Repository {
	r, err := Open(tr.dir)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
