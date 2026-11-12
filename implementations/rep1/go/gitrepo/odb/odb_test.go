package odb

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitrepo/internal/testrepo"
	"gitrepo/object"
)

func open(t *testing.T, r *testrepo.Repo) *Store {
	t.Helper()
	s, err := Open(filepath.Join(r.Dir, "objects"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestEmptyAndMissing(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "nope"))
	if err != nil {
		t.Fatal(err)
	}
	if c := s.Counts(); c != (Counts{}) {
		t.Errorf("counts = %+v", c)
	}
	if _, err := s.Read(object.ID{1}); !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v", err)
	}
	if _, err := s.Abbrev("abcd"); !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v", err)
	}
}

func TestLooseRoundTrip(t *testing.T) {
	r := testrepo.New(t)
	id := r.Blob("one file\n")
	s := open(t, r)
	o, err := s.Read(id)
	if err != nil || o.Type != object.Blob || string(o.Data) != "one file\n" {
		t.Fatalf("got %+v, %v", o, err)
	}
	if o.ID() != id {
		t.Error("id mismatch")
	}
	if !s.Has(id) || s.Has(object.ID{9}) {
		t.Error("Has wrong")
	}
	if c := s.Counts(); c != (Counts{Loose: 1}) {
		t.Errorf("counts = %+v", c)
	}
}

func TestDamagedLoose(t *testing.T) {
	r := testrepo.New(t)
	for name, plain := range map[string]string{
		"badtype":   "blobx 3\x00abc",
		"nosize":    "blob \x00abc",
		"sizewrong": "blob 4\x00abc",
		"nonul":     "blob 3abc",
		"neg":       "blob -3\x00abc",
		"huge":      "blob 99999999999999999999\x00abc",
	} {
		var id object.ID
		copy(id[:], name)
		r.LooseRaw(id, testrepo.Deflate([]byte(plain)))
		s := open(t, r)
		if _, err := s.Read(id); !errors.Is(err, ErrCorrupt) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
	// Garbage that is not zlib at all.
	var id object.ID
	id[0] = 0xee
	r.LooseRaw(id, []byte("this is not zlib"))
	if _, err := open(t, r).Read(id); !errors.Is(err, ErrCorrupt) {
		t.Errorf("garbage: err = %v", err)
	}
}

func packFixture(t *testing.T) (r *testrepo.Repo, ids []object.ID, datas [][]byte) {
	r = testrepo.New(t)
	base := bytes.Repeat([]byte("0123456789abcdef"), 100)
	v2 := append(append([]byte{}, base...), "tail two"...)
	v3 := append(append([]byte{}, v2...), "tail three"...)
	v4 := append(append([]byte{}, base...), "other branch"...)
	datas = [][]byte{base, v2, v3, v4}
	for _, d := range datas {
		ids = append(ids, object.Hash(object.Blob, d))
	}
	objs := []testrepo.PackObj{
		testrepo.Full(object.Blob, base),
		testrepo.OfsDelta(0, testrepo.MakeDelta(base, v2)),
		testrepo.OfsDelta(1, testrepo.MakeDelta(v2, v3)), // chain of two
		testrepo.RefDelta(ids[0], testrepo.MakeDelta(base, v4)),
	}
	r.WritePack("pack-a", objs, ids)
	return
}

func TestPackWithDeltas(t *testing.T) {
	r, ids, datas := packFixture(t)
	s := open(t, r)
	if c := s.Counts(); c != (Counts{InPack: 4, Packs: 1}) {
		t.Errorf("counts = %+v", c)
	}
	for i, id := range ids {
		o, err := s.Read(id)
		if err != nil {
			t.Fatalf("object %d: %v", i, err)
		}
		if o.Type != object.Blob || !bytes.Equal(o.Data, datas[i]) || o.ID() != id {
			t.Errorf("object %d wrong", i)
		}
	}
}

func TestRefDeltaAcrossPacksAndLoose(t *testing.T) {
	r := testrepo.New(t)
	base := []byte(strings.Repeat("base content ", 50))
	target := append(append([]byte{}, base...), "plus more"...)
	baseID := r.Loose(object.Blob, base) // base lives loose
	tid := object.Hash(object.Blob, target)
	r.WritePack("pack-x", []testrepo.PackObj{testrepo.RefDelta(baseID, testrepo.MakeDelta(base, target))}, []object.ID{tid})
	s := open(t, r)
	o, err := s.Read(tid)
	if err != nil || !bytes.Equal(o.Data, target) {
		t.Fatalf("got %v", err)
	}
}

func TestLoosePreferredOverPacked(t *testing.T) {
	r := testrepo.New(t)
	data := []byte("same id twice")
	id := r.Loose(object.Blob, data)
	r.WritePack("pack-p", []testrepo.PackObj{testrepo.Full(object.Blob, data)}, []object.ID{id})
	s := open(t, r)
	if c := s.Counts(); c != (Counts{Loose: 1, InPack: 1, Packs: 1}) {
		t.Errorf("counts = %+v", c)
	}
	// Now damage the loose copy: the loose one must still be the one used.
	r.LooseRaw(id, []byte("junk"))
	s = open(t, r)
	if _, err := s.Read(id); !errors.Is(err, ErrCorrupt) {
		t.Errorf("err = %v", err)
	}
}

func TestPackWithoutMatchingFileIsIgnored(t *testing.T) {
	r, _, _ := packFixture(t)
	if err := os.Remove(filepath.Join(r.Dir, "objects/pack/pack-a.pack")); err != nil {
		t.Fatal(err)
	}
	if c := open(t, r).Counts(); c != (Counts{}) {
		t.Errorf("counts = %+v", c)
	}
}

func TestMissingRefDeltaBase(t *testing.T) {
	r := testrepo.New(t)
	missing := object.ID{0xab}
	tid := object.ID{0xcd}
	r.WritePack("pack-m", []testrepo.PackObj{testrepo.RefDelta(missing, testrepo.MakeDelta([]byte("x"), []byte("xy")))}, []object.ID{tid})
	if _, err := open(t, r).Read(tid); !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v", err)
	}
}

func TestRefDeltaCycle(t *testing.T) {
	r := testrepo.New(t)
	a, b := object.ID{0x10}, object.ID{0x20}
	d := testrepo.MakeDelta([]byte("x"), []byte("x"))
	r.WritePack("pack-c", []testrepo.PackObj{testrepo.RefDelta(b, d), testrepo.RefDelta(a, d)}, []object.ID{a, b})
	if _, err := open(t, r).Read(a); !errors.Is(err, ErrCorrupt) {
		t.Errorf("err = %v", err)
	}
}

func TestAbbrev(t *testing.T) {
	r := testrepo.New(t)
	mk := func(prefix byte, rest byte) object.ID {
		var id object.ID
		id[0], id[1], id[19] = prefix, rest, 0x77
		r.LooseRaw(id, testrepo.Deflate(testrepo.Stored(object.Blob, nil)))
		return id
	}
	a := mk(0xab, 0xc1)
	b := mk(0xab, 0xc2)
	c := mk(0xde, 0xad)
	// A packed duplicate of c is still one object.
	r.WritePack("pack-d", []testrepo.PackObj{testrepo.Full(object.Blob, nil)}, []object.ID{c})
	s := open(t, r)

	if got, err := s.Abbrev("abc1"); err != nil || got != a {
		t.Errorf("abc1 -> %v, %v", got, err)
	}
	if got, err := s.Abbrev("ABC2"); err != nil || got != b {
		t.Errorf("ABC2 -> %v, %v", got, err)
	}
	if _, err := s.Abbrev("abc"); !errors.Is(err, ErrAmbiguous) {
		t.Errorf("abc: err = %v", err)
	}
	if got, err := s.Abbrev("dea"); err != nil || got != c {
		t.Errorf("dea (loose+packed dup) -> %v, %v", got, err)
	}
	if _, err := s.Abbrev("0000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("0000: err = %v", err)
	}
	if got, err := s.Abbrev(c.String()); err != nil || got != c {
		t.Errorf("full id -> %v, %v", got, err)
	}
}

func TestApplyDelta(t *testing.T) {
	base := []byte("hello world")
	for _, tc := range []struct {
		name  string
		delta []byte
		want  string
		bad   bool
	}{
		{"copy+insert", []byte{11, 8, 0x90, 5, 3, ' ', 'a', 'b'}, "hello ab", false},
		{"copy offset", []byte{11, 5, 0x91, 6, 5}, "world", false},
		{"zero size means 0x10000", []byte{11, 0, 0x80}, "", true},
		{"copy past end", []byte{11, 5, 0x91, 8, 5}, "", true},
		{"opcode zero", []byte{11, 1, 0}, "", true},
		{"short result", []byte{11, 5, 2, 'a', 'b'}, "", true},
		{"long result", []byte{11, 1, 2, 'a', 'b'}, "", true},
		{"truncated insert", []byte{11, 5, 5, 'a'}, "", true},
		{"truncated copy", []byte{11, 5, 0x91, 6}, "", true},
		{"truncated header", []byte{11}, "", true},
	} {
		got, err := ApplyDelta(base, tc.delta)
		if tc.bad {
			if !errors.Is(err, ErrCorrupt) {
				t.Errorf("%s: err = %v, want ErrCorrupt", tc.name, err)
			}
			continue
		}
		if err != nil || string(got) != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
		}
	}
	// A 0x10000-byte copy encoded with size 0.
	big := bytes.Repeat([]byte{'z'}, 0x10000)
	d := []byte{0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80} // base size, result size, copy with no args
	got, err := ApplyDelta(big, d)
	if err != nil || len(got) != 0x10000 {
		t.Errorf("size-0 copy: len %d, %v", len(got), err)
	}
}
