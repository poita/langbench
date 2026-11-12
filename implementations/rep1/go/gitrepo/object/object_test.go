package object

import (
	"bytes"
	"errors"
	"testing"
)

func TestHashKnownBlob(t *testing.T) {
	got := Hash(Blob, []byte("one file\n")).String()
	if got != "b7814cae2e925fe74c6cd5816462fff515ccb256" {
		t.Errorf("got %s", got)
	}
	if id := (&Object{Type: Blob, Data: []byte("one file\n")}).ID(); id.String() != got {
		t.Errorf("Object.ID = %s", id)
	}
	// The empty tree.
	if got := Hash(Tree, nil).String(); got != "4b825dc642cb6eb9a060e54bf8d69288fbee4904" {
		t.Errorf("empty tree = %s", got)
	}
}

func TestParseID(t *testing.T) {
	if _, err := ParseID("zz"); err == nil {
		t.Error("short id accepted")
	}
	if _, err := ParseID("g" + string(bytes.Repeat([]byte("0"), 39))); err == nil {
		t.Error("non-hex id accepted")
	}
	id, err := ParseID("B7814CAE2E925FE74C6CD5816462FFF515CCB256")
	if err != nil || id.String() != "b7814cae2e925fe74c6cd5816462fff515ccb256" {
		t.Errorf("got %v, %v", id, err)
	}
}

func TestSubject(t *testing.T) {
	for _, tc := range []struct{ msg, want string }{
		{"\n\nFix the thing   \nand the other\n\nbody\n", "Fix the thing and the other"},
		{"", ""},
		{"\n \t\n", ""},
		{"one line", "one line"},
		{"a\r\nb \x0b\n\nc", "a b"},
		{"  indented  \n", "  indented"},
		{"first\n   \nsecond", "first"},
	} {
		if got := string(Subject([]byte(tc.msg))); got != tc.want {
			t.Errorf("Subject(%q) = %q, want %q", tc.msg, got, tc.want)
		}
	}
}

func TestParseIdent(t *testing.T) {
	for _, tc := range []struct {
		in   string
		name string
		when uint64
	}{
		{"Ada Lovelace <ada@x> 1400003600 +0100", "Ada Lovelace", 1400003600},
		{"Ada   <ada@x>   42 +0000", "Ada", 42},
		{"Ada <ada@x> -7 +0000", "Ada", 7},
		{"Ada <ada@x>", "Ada", 0},
		{"Ada <ada@x> abc", "Ada", 0},
		{"No Brackets", "No Brackets", 0},
		{"A <b <c> > 5", "A", 0}, // first '>' is followed by " >", not digits
		{"<> 9", "", 9},
		{"A <b> 99999999999999999999999", "A", 1<<64 - 1},
	} {
		id := ParseIdent([]byte(tc.in))
		if string(id.Name) != tc.name || id.When != tc.when {
			t.Errorf("ParseIdent(%q) = %q, %d; want %q, %d", tc.in, id.Name, id.When, tc.name, tc.when)
		}
	}
}

const (
	tree1 = "1111111111111111111111111111111111111111"
	tree2 = "2222222222222222222222222222222222222222"
	par1  = "3333333333333333333333333333333333333333"
	par2  = "4444444444444444444444444444444444444444"
)

func TestParseCommit(t *testing.T) {
	data := "tree " + tree1 + "\nparent " + par1 + "\nparent " + par2 +
		"\nauthor A <a@x> 10 +0000\ncommitter C <c@x> 20 +0000\n" +
		"gpgsig -----BEGIN-----\n tree " + tree2 + "\n author fake <f> 1 +0000\n -----END-----\n" +
		"tree " + tree2 + "\n\nsubject\n\nbody\n"
	c, err := ParseCommit([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	if c.Tree.String() != tree2 {
		t.Errorf("last tree should win, got %s", c.Tree)
	}
	if len(c.Parents) != 2 || c.Parents[0].String() != par1 || c.Parents[1].String() != par2 {
		t.Errorf("parents = %v", c.Parents)
	}
	if string(c.Author.Name) != "A" || c.Author.When != 10 || string(c.Committer.Name) != "C" || c.Committer.When != 20 {
		t.Errorf("idents = %+v %+v", c.Author, c.Committer)
	}
	if string(c.Message) != "subject\n\nbody\n" || string(c.Subject()) != "subject" {
		t.Errorf("message = %q", c.Message)
	}
}

func TestParseCommitNoMessage(t *testing.T) {
	c, err := ParseCommit([]byte("tree " + tree1 + "\nauthor A <a> 1 +0"))
	if err != nil || len(c.Message) != 0 || c.Author.When != 1 {
		t.Errorf("got %+v, %v", c, err)
	}
}

func TestParseCommitErrors(t *testing.T) {
	for _, in := range []string{"", "author A <a> 1 +0\n\nmsg", "tree xyz\n\nmsg", "tree " + tree1 + "\nparent bad\n\n"} {
		if _, err := ParseCommit([]byte(in)); !errors.Is(err, ErrMalformed) {
			t.Errorf("ParseCommit(%q) err = %v", in, err)
		}
	}
}

func TestParseTag(t *testing.T) {
	tag, err := ParseTag([]byte("object " + tree1 + "\ntype commit\ntag v1\ntagger T <t> 5 +0\n\nmessage\n"))
	if err != nil || tag.Target.String() != tree1 || string(tag.Name) != "v1" || string(tag.Type) != "commit" || tag.Tagger.When != 5 {
		t.Errorf("got %+v, %v", tag, err)
	}
	if _, err := ParseTag([]byte("type commit\n\n")); !errors.Is(err, ErrMalformed) {
		t.Errorf("err = %v", err)
	}
}

func TestParseTree(t *testing.T) {
	var data []byte
	add := func(mode, name string, fill byte) {
		data = append(data, mode+" "+name+"\x00"...)
		data = append(data, bytes.Repeat([]byte{fill}, 20)...)
	}
	add("40000", "dir", 1)
	add("100644", "caf\xc3\xa9", 2)
	add("160000", "sub", 3)
	add("120000", "link", 4)
	es, err := ParseTree(data)
	if err != nil || len(es) != 4 {
		t.Fatalf("got %v, %v", es, err)
	}
	want := []Type{Tree, Blob, Commit, Blob}
	for i, e := range es {
		if e.Type() != want[i] {
			t.Errorf("entry %d (%q, %o) type %s, want %s", i, e.Name, e.Mode, e.Type(), want[i])
		}
	}
	if es[0].Mode != 0o40000 || string(es[1].Name) != "caf\xc3\xa9" || es[2].ID[0] != 3 {
		t.Errorf("entries = %+v", es)
	}
	for _, bad := range [][]byte{
		[]byte("100644 name"), []byte("100644 \x00" + string(make([]byte, 20))),
		data[:len(data)-1], []byte("10x644 n\x00" + string(make([]byte, 20))),
		[]byte("nomodeorspace"), []byte(" n\x00" + string(make([]byte, 20))),
	} {
		if _, err := ParseTree(bad); !errors.Is(err, ErrMalformed) {
			t.Errorf("ParseTree(%q) err = %v", bad, err)
		}
	}
	if es, err := ParseTree(nil); err != nil || len(es) != 0 {
		t.Errorf("empty tree: %v, %v", es, err)
	}
}
