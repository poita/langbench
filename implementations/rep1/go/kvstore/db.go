package tessera

import (
	"encoding/binary"
	"sort"

	"example.com/tessera/crc"
)

// DB is an open Tessera database: the main file image, the write-ahead log and
// the in-memory overlay of committed-but-not-checkpointed pages.
//
// A DB is not safe for concurrent use.
//
// The database lives entirely in memory; Open takes the bytes of an existing
// main file and log and DatabaseFile and LogFile return their updated
// contents. Nothing is ever written to the main file except by Checkpoint.
type DB struct {
	main    []byte            // contents of main.tdb
	overlay map[uint32][]byte // newest committed image of each page held in the log
	wal     []byte            // contents of main.twal: header then complete transactions
	hdr     header            // page 1, as of the open transaction (or last commit)

	inTxn bool
	saved header            // header at begin, restored on rollback
	dirty map[uint32][]byte // pages written by the open transaction
}

// ---------------------------------------------------------------------------
// Page access (SPEC §13.1, §13.2)

func (db *DB) readPage(p uint32) []byte {
	if img, ok := db.dirty[p]; ok {
		return img
	}
	if img, ok := db.overlay[p]; ok {
		return img
	}
	off := (int64(p) - 1) * PageSize
	if p >= 1 && off+PageSize <= int64(len(db.main)) {
		return db.main[off : off+PageSize : off+PageSize]
	}
	return make([]byte, PageSize)
}

// writePage stores a new image of page p in the open transaction. The slice
// must not be modified afterwards.
func (db *DB) writePage(p uint32, img []byte) {
	db.dirty[p] = img
}

func (db *DB) readNode(p uint32) *node { return decodeNode(db.readPage(p)) }

func (db *DB) writeNode(p uint32, n *node) { db.writePage(p, n.encode()) }

// allocPage implements allocate_page (SPEC §10).
func (db *DB) allocPage() uint32 {
	if db.hdr.freeHead != 0 {
		p := db.hdr.freeHead
		db.hdr.freeHead = binary.BigEndian.Uint32(db.readPage(p)[4:])
		db.hdr.freeCount--
		return p
	}
	db.hdr.pageCount++
	return db.hdr.pageCount
}

// freePage implements free_page (SPEC §10).
func (db *DB) freePage(p uint32) {
	img := make([]byte, PageSize)
	binary.BigEndian.PutUint32(img[4:], db.hdr.freeHead)
	db.writePage(p, img)
	db.hdr.freeHead = p
	db.hdr.freeCount++
}

// ---------------------------------------------------------------------------
// Write-ahead log (SPEC §15)

var magicWAL = []byte("TESSWAL1")

// walHeader returns the constant 32-byte log header.
func walHeader() []byte {
	h := make([]byte, walHeaderSize)
	copy(h, magicWAL)
	binary.BigEndian.PutUint16(h[8:], 1)
	binary.BigEndian.PutUint16(h[10:], PageSize)
	binary.BigEndian.PutUint32(h[28:], crc.Checksum(h[:28]))
	return h
}

func walHeaderValid(b []byte) bool {
	if len(b) < walHeaderSize {
		return false
	}
	if string(b[:8]) != string(magicWAL) ||
		binary.BigEndian.Uint16(b[8:]) != 1 ||
		binary.BigEndian.Uint16(b[10:]) != PageSize {
		return false
	}
	for _, c := range b[12:28] {
		if c != 0 {
			return false
		}
	}
	return binary.BigEndian.Uint32(b[28:]) == crc.Checksum(b[:28])
}

// appendRecord appends one log record to dst.
func appendRecord(dst []byte, typ byte, txn uint64, field uint32, payload []byte) []byte {
	start := len(dst)
	dst = append(dst, typ, 0, 0, 0)
	dst = binary.BigEndian.AppendUint64(dst, txn)
	dst = binary.BigEndian.AppendUint32(dst, field)
	dst = binary.BigEndian.AppendUint32(dst, uint32(len(payload)))
	sum := crc.Checksum(dst[start : start+20])
	sum = crc.Update(sum, payload)
	dst = binary.BigEndian.AppendUint32(dst, sum)
	return append(dst, payload...)
}

// ---------------------------------------------------------------------------
// Opening and recovery (SPEC §16)

// Open opens a database from the bytes of its main file and write-ahead log.
// Either may be nil or empty: an empty main file means a fresh database and an
// empty or invalid log means an empty log. The log is replayed: every
// transaction whose commit record is intact is applied to the overlay and
// everything after the last such record is discarded. The arguments are not
// modified.
func Open(mainFile, logFile []byte) *DB {
	db := &DB{overlay: make(map[uint32][]byte)}
	if len(mainFile) == 0 {
		fresh := freshHeader()
		db.main = fresh.encode()
	} else {
		db.main = append([]byte(nil), mainFile...)
	}
	db.hdr = decodeHeader(db.readPage(1))

	if !walHeaderValid(logFile) {
		db.wal = walHeader()
		return db
	}
	type frame struct {
		page    uint32
		payload []byte
	}
	var group []frame
	var groupTxn uint64
	open := false
	off := walHeaderSize
	validEnd := walHeaderSize
scan:
	for {
		rem := len(logFile) - off
		if rem < recHeaderSize {
			break
		}
		h := logFile[off : off+recHeaderSize]
		typ := h[0]
		plen := int(binary.BigEndian.Uint32(h[16:]))
		field := binary.BigEndian.Uint32(h[12:])
		if (typ != 1 && typ != 2) || h[1] != 0 || h[2] != 0 || h[3] != 0 {
			break
		}
		if (typ == 1 && plen != PageSize) || (typ == 2 && plen != 0) || field < 1 {
			break
		}
		if rem < recHeaderSize+plen {
			break
		}
		payload := logFile[off+recHeaderSize : off+recHeaderSize+plen]
		sum := crc.Update(crc.Checksum(h[:20]), payload)
		if sum != binary.BigEndian.Uint32(h[20:]) {
			break
		}
		txn := binary.BigEndian.Uint64(h[4:])
		switch typ {
		case 1:
			if open && groupTxn != txn {
				break scan
			}
			if !open {
				open, groupTxn = true, txn
			}
			group = append(group, frame{field, payload})
			off += recHeaderSize + plen
		case 2:
			if !open || groupTxn != txn || len(group) != int(field) {
				break scan
			}
			for _, f := range group {
				db.overlay[f.page] = f.payload
			}
			group, open = group[:0], false
			off += recHeaderSize
			validEnd = off
		}
	}
	db.wal = append([]byte(nil), logFile[:validEnd]...)
	if img, ok := db.overlay[1]; ok {
		db.hdr = decodeHeader(img)
	}
	return db
}

// DatabaseFile returns the contents of the main file.
func (db *DB) DatabaseFile() []byte { return append([]byte(nil), db.main...) }

// LogFile returns the contents of the write-ahead log.
func (db *DB) LogFile() []byte { return append([]byte(nil), db.wal...) }

// ---------------------------------------------------------------------------
// Transactions and checkpoints (SPEC §13, §15.6)

// CommitInfo describes a committed transaction.
type CommitInfo struct {
	TxnID  uint64 // the new commit counter
	Frames int    // page image records appended to the log
}

// InTransaction reports whether an explicit transaction is open.
func (db *DB) InTransaction() bool { return db.inTxn }

// Begin opens an explicit transaction.
func (db *DB) Begin() error {
	if db.inTxn {
		return newErr(ErrTxnActive)
	}
	db.beginTxn()
	return nil
}

func (db *DB) beginTxn() {
	db.inTxn = true
	db.saved = db.hdr
	db.dirty = make(map[uint32][]byte)
}

// Commit commits the open explicit transaction.
func (db *DB) Commit() (CommitInfo, error) {
	if !db.inTxn {
		return CommitInfo{}, newErr(ErrNoTxn)
	}
	return db.commitTxn(), nil
}

func (db *DB) commitTxn() CommitInfo {
	db.hdr.commitCounter++
	txn := db.hdr.commitCounter
	db.dirty[1] = db.hdr.encode()
	pages := make([]uint32, 0, len(db.dirty))
	for p := range db.dirty {
		pages = append(pages, p)
	}
	sort.Slice(pages, func(i, j int) bool { return pages[i] < pages[j] })
	for _, p := range pages {
		img := db.dirty[p]
		db.wal = appendRecord(db.wal, 1, txn, p, img)
		db.overlay[p] = img
	}
	db.wal = appendRecord(db.wal, 2, txn, uint32(len(pages)), nil)
	db.dirty = nil
	db.inTxn = false
	info := CommitInfo{TxnID: txn, Frames: len(pages)}
	if len(db.wal) >= WALLimit {
		db.checkpoint()
	}
	return info
}

// Rollback discards the open explicit transaction.
func (db *DB) Rollback() error {
	if !db.inTxn {
		return newErr(ErrNoTxn)
	}
	db.rollbackTxn()
	return nil
}

func (db *DB) rollbackTxn() {
	db.hdr = db.saved
	db.dirty = nil
	db.inTxn = false
}

// mutate runs fn, a modification that cannot fail, inside the open explicit
// transaction or, if there is none, inside an implicit one that commits
// immediately.
func (db *DB) mutate(fn func()) {
	if db.inTxn {
		fn()
		return
	}
	db.beginTxn()
	fn()
	db.commitTxn()
}

// Checkpoint copies every page held in the log into the main file and empties
// the log. It returns the number of pages copied.
func (db *DB) Checkpoint() (int, error) {
	if db.inTxn {
		return 0, newErr(ErrTxnActive)
	}
	return db.checkpoint(), nil
}

func (db *DB) checkpoint() int {
	n := len(db.overlay)
	pc := int(db.hdr.pageCount)
	size := pc * PageSize
	if len(db.main) > size {
		db.main = db.main[:size]
	} else if len(db.main) < size {
		db.main = append(db.main, make([]byte, size-len(db.main))...)
	}
	for p, img := range db.overlay {
		copy(db.main[(int(p)-1)*PageSize:], img)
	}
	db.overlay = make(map[uint32][]byte)
	db.wal = walHeader()
	return n
}

// ---------------------------------------------------------------------------
// Stat

// Stats is a snapshot of the engine's header fields (SPEC §19.2).
type Stats struct {
	Pages    uint32
	Free     uint32
	FreeHead uint32
	Docs     uint32
	Root     uint32
	Height   int
	Commits  uint64
	Indexes  int
	WALSize  int
}

// Stat reports the current state, including uncommitted changes of an open
// transaction. WALSize counts only committed records.
func (db *DB) Stat() Stats {
	h := &db.hdr
	return Stats{
		Pages: h.pageCount, Free: h.freeCount, FreeHead: h.freeHead,
		Docs: h.primaryCount, Root: h.primaryRoot,
		Height:  db.height(h.primaryRoot),
		Commits: h.commitCounter, Indexes: h.indexCount(),
		WALSize: len(db.wal),
	}
}

// height implements §12.7.
func (db *DB) height(root uint32) int {
	if root == 0 {
		return 0
	}
	hgt := 1
	for {
		n := db.readNode(root)
		if n.typ != typeInterior {
			return hgt
		}
		hgt++
		if len(n.cells) > 0 {
			root = n.cells[0].child
		} else {
			root = n.link
		}
	}
}
