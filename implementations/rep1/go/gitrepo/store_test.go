package gitrepo

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseID(t *testing.T) {
	s := "b7814cae2e925fe74c6cd5816462fff515ccb256"
	id, err := ParseID(strings.ToUpper(s))
	if err != nil || id.String() != s {
		t.Fatalf("ParseID: %v %v", id, err)
	}
	for _, bad := range []string{"", s[:39], s + "0", strings.Repeat("g", 40)} {
		if _, err := ParseID(bad); err == nil {
			t.Errorf("ParseID(%q) accepted", bad)
		}
	}
}

func TestHashObject(t *testing.T) {
	if got := HashObject(TypeBlob, []byte("one file\n")).String(); got != "b7814cae2e925fe74c6cd5816462fff515ccb256" {
		t.Fatalf("blob id %s", got)
	}
	if got := HashObject(TypeTree, nil).String(); got != "4b825dc642cb6eb9a060e54bf8d69288fbee4904" {
		t.Fatalf("empty tree id %s", got)
	}
}

func TestLooseObjects(t *testing.T) {
	tr := newTestRepo(t)
	id := tr.loose(TypeBlob, []byte("one file\n"))
	r := mustOpen(t, tr)
	typ, data, err := r.VerifyObject(id)
	if err != nil || typ != TypeBlob || string(data) != "one file\n" {
		t.Fatalf("got %v %q %v", typ, data, err)
	}
	if l, p, k := r.Counts(); l != 1 || p != 0 || k != 0 {
		t.Errorf("Counts = %d %d %d", l, p, k)
	}
	if _, _, err := r.ReadObject(ID{1}); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing object: %v", err)
	}
}

func TestDamagedLooseObjects(t *testing.T) {
	tr := newTestRepo(t)
	write := func(stored string) ID {
		id := HashObject(TypeBlob, []byte("zzz")) // arbitrary distinct names
		_ = id
		fake := ID{}
		copy(fake[:], stored)
		h := fake.String()
		tr.write("objects/"+h[:2]+"/"+h[2:], zdeflate([]byte(stored)))
		return fake
	}
	cases := map[string]ID{
		"wrong size":   write("blob 5\x00abc"),
		"unknown type": write("blorb 3\x00abc"),
		"missing nul":  write("blob 3 abc"),
		"leading zero": write("blob 03\x00abc"),
		"garbage zlib": {},
	}
	garbage := ID{9, 9, 9}
	h := garbage.String()
	tr.write("objects/"+h[:2]+"/"+h[2:], []byte("not zlib at all"))
	cases["garbage zlib"] = garbage
	r := mustOpen(t, tr)
	for name, id := range cases {
		if _, _, err := r.ReadObject(id); !errors.Is(err, ErrDamaged) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
	// Damaged files are still counted.
	if l, _, _ := r.Counts(); l != len(cases) {
		t.Errorf("loose count %d, want %d", l, len(cases))
	}
}

func TestVerifyDetectsWrongContent(t *testing.T) {
	tr := newTestRepo(t)
	good := tr.loose(TypeBlob, []byte("hello"))
	// Store other content under good's name.
	h := good.String()
	tr.write("objects/"+h[:2]+"/"+h[2:], zdeflate([]byte("blob 5\x00world")))
	r := mustOpen(t, tr)
	if _, _, err := r.ReadObject(good); err != nil {
		t.Fatalf("ReadObject: %v", err)
	}
	if _, _, err := r.VerifyObject(good); err == nil {
		t.Fatal("VerifyObject accepted a mismatched object")
	}
}

func TestLooseFileListing(t *testing.T) {
	tr := newTestRepo(t)
	tr.loose(TypeBlob, []byte("a"))
	tr.write("objects/ab/short", nil)
	tr.write("objects/0G/"+strings.Repeat("c", 38), nil)
	tr.write("objects/info/packs", nil)
	tr.write("objects/zz/"+strings.Repeat("c", 38), nil)
	tr.write("objects/ab/"+strings.Repeat("C", 38), nil)
	r := mustOpen(t, tr)
	if l, _, _ := r.Counts(); l != 1 {
		t.Errorf("loose = %d, want 1", l)
	}
}

func TestPacks(t *testing.T) {
	tr := newTestRepo(t)
	base := bytes.Repeat([]byte("0123456789abcdef"), 40)
	target1 := append(append([]byte{}, base[:300]...), []byte("-- tail one --")...)
	target2 := append(append([]byte{}, target1[:310]...), []byte("++ tail two ++")...)
	idBase := HashObject(TypeBlob, base)
	id1 := HashObject(TypeBlob, target1)
	id2 := HashObject(TypeBlob, target2)
	idRef := HashObject(TypeBlob, []byte("ref delta result"))
	tr.writePack("pack-one", []packObject{
		{typ: 3, payload: base, id: idBase},
		{typ: 6, baseIdx: 0, payload: deltaFor(len(base), target1, 300), id: id1},
		{typ: 6, baseIdx: 1, payload: deltaFor(len(target1), target2, 310), id: id2}, // chain
	})
	// A ref-delta in a second pack whose base is in the first pack.
	tr.writePack("pack-two", []packObject{
		{typ: 7, baseID: idBase, payload: deltaFor(len(base), []byte("ref delta result"), 0), id: idRef},
	})
	// An orphan .idx and an orphan .pack must be ignored.
	tr.write("objects/pack/orphan.idx", []byte("junk"))
	tr.write("objects/pack/orphan2.pack", []byte("junk"))

	r := mustOpen(t, tr)
	for id, want := range map[ID][]byte{idBase: base, id1: target1, id2: target2, idRef: []byte("ref delta result")} {
		typ, data, err := r.VerifyObject(id)
		if err != nil || typ != TypeBlob || !bytes.Equal(data, want) {
			t.Fatalf("object %s: %v %v", id, typ, err)
		}
	}
	if l, p, k := r.Counts(); l != 0 || p != 4 || k != 2 {
		t.Errorf("Counts = %d %d %d, want 0 4 2", l, p, k)
	}
	if !r.HasObject(id2) || r.HasObject(ID{7}) {
		t.Error("HasObject wrong")
	}
	got, err := r.Abbrev(id2.String()[:8])
	if err != nil || got != id2 {
		t.Errorf("Abbrev: %v %v", got, err)
	}
}

func TestRefDeltaWithLooseBaseAndLoosePreferred(t *testing.T) {
	tr := newTestRepo(t)
	base := []byte(strings.Repeat("base content\n", 20))
	baseID := tr.loose(TypeBlob, base)
	target := append(append([]byte{}, base[:100]...), []byte("changed")...)
	targetID := HashObject(TypeBlob, target)
	tr.writePack("p", []packObject{
		{typ: 7, baseID: baseID, payload: deltaFor(len(base), target, 100), id: targetID},
		{typ: 3, payload: []byte("packed copy"), id: HashObject(TypeBlob, []byte("shadowed"))},
	})
	// A loose object that shadows the packed one with different content.
	shadowID := HashObject(TypeBlob, []byte("shadowed"))
	h := shadowID.String()
	tr.write("objects/"+h[:2]+"/"+h[2:], zdeflate([]byte("blob 8\x00shadowed")))
	r := mustOpen(t, tr)
	if _, data, err := r.VerifyObject(targetID); err != nil || !bytes.Equal(data, target) {
		t.Fatalf("ref delta on loose base: %v", err)
	}
	if _, data, err := r.ReadObject(shadowID); err != nil || string(data) != "shadowed" {
		t.Fatalf("loose should win over pack: %q %v", data, err)
	}
}

func TestBadDeltas(t *testing.T) {
	base := []byte("0123456789")
	good := deltaFor(len(base), []byte("0123xyz"), 4)
	if out, err := applyDelta(base, good); err != nil || string(out) != "0123xyz" {
		t.Fatalf("good delta: %q %v", out, err)
	}
	cases := map[string][]byte{
		"zero opcode":      {10, 3, 0},
		"copy past base":   {10, 5, 0x91, 8, 5},
		"result too short": {10, 9, 1, 'x'},
		"result too long":  {10, 1, 2, 'x', 'y'},
		"truncated insert": {10, 5, 5, 'a'},
		"truncated copy":   {10, 5, 0x91, 0},
		"truncated header": {0x80},
	}
	for name, d := range cases {
		if _, err := applyDelta(base, d); !errors.Is(err, ErrDamaged) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
	// copy size 0 means 0x10000
	big := bytes.Repeat([]byte{'x'}, 0x10000)
	d := []byte{0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80}
	if out, err := applyDelta(big, d); err != nil || len(out) != 0x10000 {
		t.Errorf("size-0 copy: %v", err)
	}
}

func TestPackCycleAndBadTypes(t *testing.T) {
	tr := newTestRepo(t)
	a := HashObject(TypeBlob, []byte("a"))
	// A ref-delta whose base is itself must fail, not hang.
	tr.writePack("cycle", []packObject{{typ: 7, baseID: a, payload: deltaFor(1, []byte("a"), 1), id: a}})
	b := HashObject(TypeBlob, []byte("b"))
	tr.writePack("badtype", []packObject{{typ: 5, payload: []byte("b"), id: b}})
	r := mustOpen(t, tr)
	for _, id := range []ID{a, b} {
		if _, _, err := r.ReadObject(id); !errors.Is(err, ErrDamaged) {
			t.Errorf("%s: err = %v", id, err)
		}
	}
}

func TestAbbrev(t *testing.T) {
	tr := newTestRepo(t)
	ids := []ID{}
	for _, s := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		ids = append(ids, tr.loose(TypeBlob, []byte(s)))
	}
	r := mustOpen(t, tr)
	for _, id := range ids {
		for _, n := range []int{8, 20, 39} {
			got, err := r.Abbrev(id.String()[:n])
			if err != nil || got != id {
				t.Errorf("Abbrev(%s[:%d]) = %v, %v", id, n, got, err)
			}
		}
	}
	if _, err := r.Abbrev("abc"); err == nil {
		t.Error("3-digit abbreviation accepted")
	}
	if _, err := r.Abbrev("0000"); err == nil && !r.HasObject(ID{}) {
		t.Error("nonexistent prefix accepted")
	}
	if _, err := os.Stat(filepath.Join(tr.dir, "objects")); err != nil {
		t.Fatal(err)
	}
}
