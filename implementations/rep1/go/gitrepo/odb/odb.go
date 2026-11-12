// Package odb reads a git object database straight from disk: loose objects,
// version-2 pack indexes, packfiles, and OFS_DELTA / REF_DELTA reconstruction.
//
// A Store inspects the database once, when it is opened (which loose objects
// exist, which packs are usable). It then reads each object at most once:
// every reconstructed object is kept for the lifetime of the Store.
//
// A Store is not safe for concurrent use.
package odb

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"gitrepo/inflate"
	"gitrepo/object"
)

var (
	// ErrNotFound means the object is not in the database.
	ErrNotFound = errors.New("object not found")
	// ErrAmbiguous means an abbreviated id matches more than one object.
	ErrAmbiguous = errors.New("ambiguous object id prefix")
	// ErrCorrupt is wrapped by errors about damaged objects, packs or deltas.
	ErrCorrupt = errors.New("corrupt object")
)

func corrupt(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrCorrupt, fmt.Sprintf(format, args...))
}

// maxDeltaDepth bounds delta chains so that a cyclic REF_DELTA cannot recurse
// forever. Git's own default maximum depth is 50.
const maxDeltaDepth = 4096

// Counts summarises the contents of a database, as `count-objects` reports.
type Counts struct {
	Loose  int // loose object files, including damaged and duplicated ones
	InPack int // objects across all packs' indexes (duplicates counted twice)
	Packs  int // usable packs (an .idx with a matching .pack)
}

// Store is an opened object database.
type Store struct {
	dir      string // the objects directory
	loose    []object.ID
	looseSet map[object.ID]struct{}
	packs    []*pack
	cache    map[object.ID]*object.Object
}

// Open opens the object database in dir (the "objects" directory of a
// repository). A missing or empty directory is an empty database. Packs whose
// index or pack header is unusable are ignored.
func Open(dir string) (*Store, error) {
	s := &Store{
		dir:      dir,
		looseSet: map[object.ID]struct{}{},
		cache:    map[object.ID]*object.Object{},
	}
	s.scanLoose()
	s.scanPacks()
	return s, nil
}

func isLowerHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func (s *Store) scanLoose() {
	dirs, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	for _, d := range dirs {
		name := d.Name()
		if len(name) != 2 || !isLowerHex(name) || !d.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(s.dir, name))
		if err != nil {
			continue
		}
		for _, f := range files {
			rest := f.Name()
			if len(rest) != 38 || !isLowerHex(rest) || f.IsDir() {
				continue
			}
			id, err := object.ParseID(name + rest)
			if err != nil {
				continue
			}
			s.loose = append(s.loose, id)
			s.looseSet[id] = struct{}{}
		}
	}
	sort.Slice(s.loose, func(i, j int) bool { return bytes.Compare(s.loose[i][:], s.loose[j][:]) < 0 })
}

func (s *Store) scanPacks() {
	dir := filepath.Join(s.dir, "pack")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		if n := e.Name(); filepath.Ext(n) == ".idx" && !e.IsDir() {
			names = append(names, n[:len(n)-len(".idx")])
		}
	}
	sort.Strings(names)
	for _, n := range names {
		p, err := openPack(filepath.Join(dir, n+".idx"), filepath.Join(dir, n+".pack"))
		if err == nil {
			s.packs = append(s.packs, p)
		}
	}
}

// Counts reports how many loose objects, packed objects and packs there are.
func (s *Store) Counts() Counts {
	c := Counts{Loose: len(s.loose), Packs: len(s.packs)}
	for _, p := range s.packs {
		c.InPack += p.n
	}
	return c
}

// Has reports whether an object with the given id is present: as a loose file
// or as an entry in a pack index. The object's content is not read.
func (s *Store) Has(id object.ID) bool {
	if _, ok := s.looseSet[id]; ok {
		return true
	}
	for _, p := range s.packs {
		if _, ok := p.find(id); ok {
			return true
		}
	}
	return false
}

// Abbrev resolves a hexadecimal prefix (1 to 40 digits, any case) to the id
// of the one object in the database that it begins. It returns ErrNotFound for
// no match and ErrAmbiguous for several. An object stored both loose and in a
// pack, or in several packs, is a single object.
func (s *Store) Abbrev(prefix string) (object.ID, error) {
	var lo, hi object.ID
	for i := 0; i < len(prefix); i++ {
		c := prefix[i]
		var v byte
		switch {
		case c >= '0' && c <= '9':
			v = c - '0'
		case c >= 'a' && c <= 'f':
			v = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			v = c - 'A' + 10
		default:
			return lo, fmt.Errorf("bad hex digit %q in %q", c, prefix)
		}
		if i >= 2*object.IDSize {
			return lo, fmt.Errorf("prefix %q too long", prefix)
		}
		if i%2 == 0 {
			lo[i/2] |= v << 4
		} else {
			lo[i/2] |= v
		}
	}
	hi = lo
	for i := len(prefix); i < 2*object.IDSize; i++ {
		if i%2 == 0 {
			hi[i/2] |= 0xf0
		} else {
			hi[i/2] |= 0x0f
		}
	}

	var found object.ID
	n := 0
	note := func(id object.ID) bool { // reports whether to stop (ambiguous)
		if n == 1 && id == found {
			return false
		}
		found = id
		n++
		return n > 1
	}
	i := sort.Search(len(s.loose), func(i int) bool { return bytes.Compare(s.loose[i][:], lo[:]) >= 0 })
	for ; i < len(s.loose) && bytes.Compare(s.loose[i][:], hi[:]) <= 0; i++ {
		if note(s.loose[i]) {
			return found, ErrAmbiguous
		}
	}
	for _, p := range s.packs {
		for i := p.lowerBound(lo); i < p.n; i++ {
			id := p.idAt(i)
			if bytes.Compare(id[:], hi[:]) > 0 {
				break
			}
			if note(id) {
				return found, ErrAmbiguous
			}
		}
	}
	if n == 0 {
		return found, ErrNotFound
	}
	return found, nil
}

// Read returns the object with the given id, preferring a loose copy over a
// packed one. The content is decompressed and, for deltas, reconstructed, but
// the id is not verified: use Object.ID for that. The returned Object is
// shared with the cache and must not be modified.
func (s *Store) Read(id object.ID) (*object.Object, error) {
	return s.read(id, 0)
}

func (s *Store) read(id object.ID, depth int) (*object.Object, error) {
	if o, ok := s.cache[id]; ok {
		return o, nil
	}
	var o *object.Object
	var err error
	if _, ok := s.looseSet[id]; ok {
		o, err = s.readLoose(id)
	} else {
		found := false
		for _, p := range s.packs {
			if off, ok := p.find(id); ok {
				o, err = s.readPacked(p, off, depth)
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, id)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("object %s: %w", id, err)
	}
	s.cache[id] = o
	return o, nil
}

func (s *Store) readLoose(id object.ID) (*object.Object, error) {
	hexid := id.String()
	raw, err := os.ReadFile(filepath.Join(s.dir, hexid[:2], hexid[2:]))
	if err != nil {
		return nil, err
	}
	plain, _, err := inflate.Zlib(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCorrupt, err)
	}
	return parseLoose(plain)
}

// parseLoose validates the "<type> <size>\0" prefix of a loose object's
// plaintext and returns the object.
func parseLoose(plain []byte) (*object.Object, error) {
	sp := bytes.IndexByte(plain, ' ')
	if sp < 0 {
		return nil, corrupt("no type in object header")
	}
	t, ok := object.ParseType(plain[:sp])
	if !ok {
		return nil, corrupt("unknown object type %q", plain[:sp])
	}
	rest := plain[sp+1:]
	nul := bytes.IndexByte(rest, 0)
	if nul <= 0 || nul > 18 {
		return nil, corrupt("bad size in object header")
	}
	size, err := strconv.ParseUint(string(rest[:nul]), 10, 63)
	if err != nil || rest[0] == '+' || rest[0] == '-' {
		return nil, corrupt("bad size in object header")
	}
	body := rest[nul+1:]
	if uint64(len(body)) != size {
		return nil, corrupt("object size %d does not match header %d", len(body), size)
	}
	return &object.Object{Type: t, Data: body}, nil
}

// Pack object types.
const (
	packCommit   = 1
	packTree     = 2
	packBlob     = 3
	packTag      = 4
	packOfsDelta = 6
	packRefDelta = 7
)

func (s *Store) readPacked(p *pack, off int, depth int) (*object.Object, error) {
	if o, ok := p.cache[off]; ok {
		return o, nil
	}
	if depth > maxDeltaDepth {
		return nil, corrupt("delta chain too deep")
	}
	data := p.data
	end := len(data) - 20
	if off < 12 || off >= end {
		return nil, corrupt("pack offset %d out of range", off)
	}
	pos := off
	b := data[pos]
	pos++
	typ := int(b>>4) & 7
	size := uint64(b & 15)
	shift := uint(4)
	for b&0x80 != 0 {
		if pos >= end || shift > 56 {
			return nil, corrupt("bad packed object header")
		}
		b = data[pos]
		pos++
		size |= uint64(b&0x7f) << shift
		shift += 7
	}
	if size > 1<<31 {
		return nil, corrupt("packed object too large")
	}

	var baseOff int
	var baseID object.ID
	switch typ {
	case packOfsDelta:
		if pos >= end {
			return nil, corrupt("truncated delta header")
		}
		b = data[pos]
		pos++
		v := uint64(b & 0x7f)
		for b&0x80 != 0 {
			if pos >= end || v > 1<<56 {
				return nil, corrupt("bad delta base offset")
			}
			b = data[pos]
			pos++
			v = (v+1)<<7 | uint64(b&0x7f)
		}
		if v == 0 || v > uint64(off-12) {
			return nil, corrupt("delta base offset out of range")
		}
		baseOff = off - int(v)
	case packRefDelta:
		if pos+object.IDSize > end {
			return nil, corrupt("truncated delta header")
		}
		copy(baseID[:], data[pos:])
		pos += object.IDSize
	case packCommit, packTree, packBlob, packTag:
	default:
		return nil, corrupt("invalid packed object type %d", typ)
	}

	payload, _, err := inflate.Zlib(data[pos:end], int(size))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCorrupt, err)
	}
	if uint64(len(payload)) != size {
		return nil, corrupt("packed object size %d does not match header %d", len(payload), size)
	}

	var o *object.Object
	switch typ {
	case packCommit:
		o = &object.Object{Type: object.Commit, Data: payload}
	case packTree:
		o = &object.Object{Type: object.Tree, Data: payload}
	case packBlob:
		o = &object.Object{Type: object.Blob, Data: payload}
	case packTag:
		o = &object.Object{Type: object.Tag, Data: payload}
	default:
		var base *object.Object
		if typ == packOfsDelta {
			base, err = s.readPacked(p, baseOff, depth+1)
		} else {
			base, err = s.read(baseID, depth+1)
		}
		if err != nil {
			return nil, err
		}
		result, err := ApplyDelta(base.Data, payload)
		if err != nil {
			return nil, err
		}
		o = &object.Object{Type: base.Type, Data: result}
	}
	p.cache[off] = o
	return o, nil
}

// ApplyDelta applies a git delta stream to base and returns the result. It
// fails with ErrCorrupt if the delta is malformed, copies past the end of the
// base, or does not produce the size it declares.
func ApplyDelta(base, delta []byte) ([]byte, error) {
	pos := 0
	varint := func() (uint64, bool) {
		var v uint64
		for shift := uint(0); shift < 64; shift += 7 {
			if pos >= len(delta) {
				return 0, false
			}
			b := delta[pos]
			pos++
			v |= uint64(b&0x7f) << shift
			if b&0x80 == 0 {
				return v, true
			}
		}
		return 0, false
	}
	if _, ok := varint(); !ok { // declared base size: not enforced
		return nil, corrupt("truncated delta header")
	}
	resSize, ok := varint()
	if !ok || resSize > 1<<31 {
		return nil, corrupt("bad delta result size")
	}
	out := make([]byte, 0, resSize)
	for pos < len(delta) {
		op := delta[pos]
		pos++
		switch {
		case op&0x80 != 0:
			var off, n uint64
			for i := uint(0); i < 4; i++ {
				if op&(1<<i) != 0 {
					if pos >= len(delta) {
						return nil, corrupt("truncated delta copy")
					}
					off |= uint64(delta[pos]) << (8 * i)
					pos++
				}
			}
			for i := uint(0); i < 3; i++ {
				if op&(0x10<<i) != 0 {
					if pos >= len(delta) {
						return nil, corrupt("truncated delta copy")
					}
					n |= uint64(delta[pos]) << (8 * i)
					pos++
				}
			}
			if n == 0 {
				n = 0x10000
			}
			if off > uint64(len(base)) || n > uint64(len(base))-off {
				return nil, corrupt("delta copy past end of base")
			}
			out = append(out, base[off:off+n]...)
		case op != 0:
			n := int(op)
			if pos+n > len(delta) {
				return nil, corrupt("truncated delta insert")
			}
			out = append(out, delta[pos:pos+n]...)
			pos += n
		default:
			return nil, corrupt("invalid delta opcode 0")
		}
		if uint64(len(out)) > resSize {
			return nil, corrupt("delta result larger than declared")
		}
	}
	if uint64(len(out)) != resSize {
		return nil, corrupt("delta result size %d, declared %d", len(out), resSize)
	}
	return out, nil
}
