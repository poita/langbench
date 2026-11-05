package gitrepo

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"gitrepo/inflate"
	"gitrepo/sha1"
)

// rawObject is an undecoded object: its type and payload.
type rawObject struct {
	Type ObjectType
	Data []byte
}

// Repository is an open git repository. Everything decoded from it is kept
// for the life of the value. It is not safe for concurrent use.
type Repository struct {
	dir string

	loose map[ID]struct{} // ids of well-formed loose object files
	packs []*pack

	inf        *inflate.Decoder
	packCache  map[packKey]*rawObject
	looseCache map[ID]*rawObject // nil value memoises a failure
	commits    map[ID]*Commit    // nil value memoises a failure
	trees      map[ID]*Tree      // nil value memoises a failure

	allIDs []ID // sorted, de-duplicated; built on first abbreviation

	packedRefs map[string]ID
	refCache   map[string]refResult
}

// Open opens the repository whose git directory (or bare repository) is dir.
// Only the object listing and the pack files are read here; missing optional
// parts (no objects directory, no packs) are not errors, but a dir that is
// not a directory is.
func Open(dir string) (*Repository, error) {
	st, err := os.Stat(dir)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, fmt.Errorf("gitrepo: %s is not a directory", dir)
	}
	r := &Repository{
		dir:        dir,
		loose:      make(map[ID]struct{}),
		inf:        inflate.NewDecoder(),
		packCache:  make(map[packKey]*rawObject),
		looseCache: make(map[ID]*rawObject),
		commits:    make(map[ID]*Commit),
		trees:      make(map[ID]*Tree),
		refCache:   make(map[string]refResult),
	}
	r.listLoose()
	r.loadPacks()
	return r, nil
}

func isLowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func (r *Repository) listLoose() {
	objDir := filepath.Join(r.dir, "objects")
	dirs, err := os.ReadDir(objDir)
	if err != nil {
		return
	}
	for _, d := range dirs {
		if !d.IsDir() || !isLowerHex(d.Name(), 2) {
			continue
		}
		files, err := os.ReadDir(filepath.Join(objDir, d.Name()))
		if err != nil {
			continue
		}
		for _, f := range files {
			if !f.Type().IsRegular() || !isLowerHex(f.Name(), 38) {
				continue
			}
			if id, err := ParseID(d.Name() + f.Name()); err == nil {
				r.loose[id] = struct{}{}
			}
		}
	}
}

func (r *Repository) loadPacks() {
	packDir := filepath.Join(r.dir, "objects", "pack")
	entries, err := os.ReadDir(packDir)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		n := e.Name()
		if e.Type().IsRegular() && filepath.Ext(n) == ".idx" {
			names = append(names, n[:len(n)-4])
		}
	}
	sort.Strings(names)
	for _, n := range names {
		idx, err := os.ReadFile(filepath.Join(packDir, n+".idx"))
		if err != nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join(packDir, n+".pack"))
		if err != nil {
			continue
		}
		if p, err := parsePack(n, idx, data); err == nil {
			r.packs = append(r.packs, p)
		}
	}
}

// Counts reports the number of loose object files, the number of objects
// across all packs (an object in two packs counts twice) and the number of
// packs.
func (r *Repository) Counts() (loose, inPack, packs int) {
	for _, p := range r.packs {
		inPack += p.n
	}
	return len(r.loose), inPack, len(r.packs)
}

// HasObject reports whether id is present as a loose file or in a pack
// index. The object's content is not read.
func (r *Repository) HasObject(id ID) bool {
	if _, ok := r.loose[id]; ok {
		return true
	}
	for _, p := range r.packs {
		if _, ok := p.find(&id); ok {
			return true
		}
	}
	return false
}

// ReadObject returns the type and payload of the object with the given id.
// The payload is shared with the repository's cache and must not be
// modified. Loose objects are preferred over packed copies. The object's
// hash is not verified; see VerifyObject.
func (r *Repository) ReadObject(id ID) (ObjectType, []byte, error) {
	o, err := r.readObject(id, 0)
	if err != nil {
		return TypeInvalid, nil, err
	}
	return o.Type, o.Data, nil
}

func (r *Repository) readObject(id ID, depth int) (*rawObject, error) {
	if _, ok := r.loose[id]; ok {
		return r.readLoose(id)
	}
	for _, p := range r.packs {
		if i, ok := p.find(&id); ok {
			off, ok := p.offset(i)
			if !ok {
				return nil, fmt.Errorf("%w: bad offset for %s", ErrDamaged, id)
			}
			return r.readPacked(p, off, depth)
		}
	}
	return nil, fmt.Errorf("%w: %s", ErrNotFound, id)
}

func (r *Repository) readLoose(id ID) (*rawObject, error) {
	if o, ok := r.looseCache[id]; ok {
		if o == nil {
			return nil, fmt.Errorf("%w: loose object %s", ErrDamaged, id)
		}
		return o, nil
	}
	o, err := r.loadLoose(id)
	if err != nil {
		r.looseCache[id] = nil
		return nil, err
	}
	r.looseCache[id] = o
	return o, nil
}

func (r *Repository) loadLoose(id ID) (*rawObject, error) {
	h := id.String()
	raw, err := os.ReadFile(filepath.Join(r.dir, "objects", h[:2], h[2:]))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDamaged, err)
	}
	plain, _, err := r.inf.Zlib(raw, len(raw)*4)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDamaged, err)
	}
	sp := bytes.IndexByte(plain, ' ')
	nul := bytes.IndexByte(plain, 0)
	if sp < 0 || nul < sp {
		return nil, fmt.Errorf("%w: bad object header", ErrDamaged)
	}
	typ := parseTypeName(plain[:sp])
	sizeStr := string(plain[sp+1 : nul])
	size, err := strconv.ParseUint(sizeStr, 10, 63)
	if typ == TypeInvalid || err != nil || sizeStr == "" || sizeStr[0] == '+' ||
		(len(sizeStr) > 1 && sizeStr[0] == '0') || uint64(len(plain)-nul-1) != size {
		return nil, fmt.Errorf("%w: bad object header", ErrDamaged)
	}
	return &rawObject{Type: typ, Data: plain[nul+1:]}, nil
}

// HashObject computes the id of an object with the given type and payload:
// the SHA-1 of "<type> <size>\0<payload>".
func HashObject(t ObjectType, data []byte) ID {
	d := sha1.New()
	d.Write(appendUint(append([]byte(t.String()), ' '), uint64(len(data))))
	d.Write([]byte{0})
	d.Write(data)
	return ID(d.Sum())
}

// VerifyObject reads the object and checks that its stored form hashes to
// id.
func (r *Repository) VerifyObject(id ID) (ObjectType, []byte, error) {
	t, data, err := r.ReadObject(id)
	if err != nil {
		return t, nil, err
	}
	if HashObject(t, data) != id {
		return TypeInvalid, nil, fmt.Errorf("%w: hash mismatch for %s", ErrDamaged, id)
	}
	return t, data, nil
}

// Commit returns the parsed commit with the given id (cached).
func (r *Repository) Commit(id ID) (*Commit, error) {
	if c, ok := r.commits[id]; ok {
		if c == nil {
			return nil, fmt.Errorf("%w: commit %s", ErrDamaged, id)
		}
		return c, nil
	}
	c, err := r.loadCommit(id)
	r.commits[id] = c
	return c, err
}

func (r *Repository) loadCommit(id ID) (*Commit, error) {
	t, data, err := r.ReadObject(id)
	if err != nil {
		return nil, err
	}
	if t != TypeCommit {
		return nil, fmt.Errorf("%w: %s is a %s, not a commit", ErrType, id, t)
	}
	return parseCommit(data)
}

// Tree returns the parsed tree with the given id (cached).
func (r *Repository) Tree(id ID) (*Tree, error) {
	if t, ok := r.trees[id]; ok {
		if t == nil {
			return nil, fmt.Errorf("%w: tree %s", ErrDamaged, id)
		}
		return t, nil
	}
	t, err := r.loadTree(id)
	r.trees[id] = t
	return t, err
}

func (r *Repository) loadTree(id ID) (*Tree, error) {
	typ, data, err := r.ReadObject(id)
	if err != nil {
		return nil, err
	}
	if typ != TypeTree {
		return nil, fmt.Errorf("%w: %s is a %s, not a tree", ErrType, id, typ)
	}
	return parseTree(data)
}

// allObjectIDs returns every object id (loose and indexed), sorted and
// de-duplicated.
func (r *Repository) allObjectIDs() []ID {
	if r.allIDs != nil {
		return r.allIDs
	}
	ids := make([]ID, 0, len(r.loose))
	for id := range r.loose {
		ids = append(ids, id)
	}
	for _, p := range r.packs {
		for i := 0; i < p.n; i++ {
			var id ID
			copy(id[:], p.idAt(i))
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return bytes.Compare(ids[i][:], ids[j][:]) < 0 })
	out := ids[:0]
	for i, id := range ids {
		if i == 0 || id != ids[i-1] {
			out = append(out, id)
		}
	}
	r.allIDs = out
	return out
}

// Abbrev resolves a hexadecimal prefix (4 to 40 digits, either case) to the
// unique object id it begins. It fails if zero or several objects match.
func (r *Repository) Abbrev(prefix string) (ID, error) {
	var zero ID
	if len(prefix) < 4 || len(prefix) > 40 {
		return zero, ErrRevision
	}
	var lo, hi ID // inclusive bounds of the prefix range
	for i := 0; i < len(prefix); i++ {
		v := hexVal(prefix[i])
		if v < 0 {
			return zero, ErrRevision
		}
		if i%2 == 0 {
			lo[i/2] = byte(v << 4)
			hi[i/2] = byte(v<<4 | 15)
		} else {
			lo[i/2] |= byte(v)
			hi[i/2] = hi[i/2]&0xf0 | byte(v)
		}
	}
	for i := (len(prefix) + 1) / 2; i < IDSize; i++ {
		hi[i] = 0xff
	}
	ids := r.allObjectIDs()
	first := sort.Search(len(ids), func(i int) bool { return bytes.Compare(ids[i][:], lo[:]) >= 0 })
	end := sort.Search(len(ids), func(i int) bool { return bytes.Compare(ids[i][:], hi[:]) > 0 })
	if end-first != 1 {
		return zero, fmt.Errorf("%w: %q matches %d objects", ErrRevision, prefix, end-first)
	}
	return ids[first], nil
}
