package engine

import (
	"bytes"
	"encoding/binary"

	"example.com/kvstore/crc"
)

// walHeader returns the constant 32-byte log header.
func walHeader() []byte {
	h := make([]byte, walHeaderSize)
	copy(h, "TESSWAL1")
	binary.BigEndian.PutUint16(h[8:], 1)
	binary.BigEndian.PutUint16(h[10:], PageSize)
	binary.BigEndian.PutUint32(h[28:], crc.Checksum(h[:28]))
	return h
}

// appendRecord appends one log record to dst. typ 1 is a page image (arg is
// the page number, payload the 1024-byte image); typ 2 is a commit record
// (arg is the frame count, payload nil).
func appendRecord(dst []byte, typ byte, txn uint64, arg uint32, payload []byte) []byte {
	var h [recHeaderSize]byte
	h[0] = typ
	binary.BigEndian.PutUint64(h[4:], txn)
	binary.BigEndian.PutUint32(h[12:], arg)
	binary.BigEndian.PutUint32(h[16:], uint32(len(payload)))
	sum := crc.Update(crc.Checksum(h[:20]), payload)
	binary.BigEndian.PutUint32(h[20:], sum)
	dst = append(dst, h[:]...)
	return append(dst, payload...)
}

// validWALHeader reports whether b begins with a correct log header.
func validWALHeader(b []byte) bool {
	if len(b) < walHeaderSize {
		return false
	}
	if !bytes.Equal(b[:8], []byte("TESSWAL1")) {
		return false
	}
	if binary.BigEndian.Uint16(b[8:]) != 1 || binary.BigEndian.Uint16(b[10:]) != PageSize {
		return false
	}
	for _, c := range b[12:28] {
		if c != 0 {
			return false
		}
	}
	return binary.BigEndian.Uint32(b[28:]) == crc.Checksum(b[:28])
}

type frame struct {
	page uint32
	img  []byte
}

// scanWAL replays the committed transactions of an input log. It returns the
// resulting overlay and the offset just past the last accepted commit record
// (the log is to be trimmed to that length). An invalid header discards the
// whole log.
func scanWAL(b []byte) (overlay map[uint32][]byte, validEnd int) {
	overlay = map[uint32][]byte{}
	if !validWALHeader(b) {
		return overlay, walHeaderSize
	}
	validEnd = walHeaderSize
	off := walHeaderSize
	var group []frame
	var groupTxn uint64
	open := false
	for {
		rem := len(b) - off
		if rem < recHeaderSize {
			break
		}
		h := b[off : off+recHeaderSize]
		typ := h[0]
		if typ != 1 && typ != 2 {
			break
		}
		if h[1] != 0 || h[2] != 0 || h[3] != 0 {
			break
		}
		txn := binary.BigEndian.Uint64(h[4:])
		arg := binary.BigEndian.Uint32(h[12:])
		plen := binary.BigEndian.Uint32(h[16:])
		if (typ == 1 && plen != PageSize) || (typ == 2 && plen != 0) {
			break
		}
		if arg < 1 {
			break
		}
		if rem < recHeaderSize+int(plen) {
			break
		}
		payload := b[off+recHeaderSize : off+recHeaderSize+int(plen)]
		if binary.BigEndian.Uint32(h[20:]) != crc.Update(crc.Checksum(h[:20]), payload) {
			break
		}
		if typ == 1 {
			if open && groupTxn != txn {
				break
			}
			if !open {
				open, groupTxn, group = true, txn, group[:0]
			}
			group = append(group, frame{arg, payload})
			off += recHeaderSize + PageSize
			continue
		}
		if !open || groupTxn != txn || len(group) != int(arg) {
			break
		}
		for _, f := range group {
			overlay[f.page] = f.img
		}
		open = false
		group = group[:0]
		off += recHeaderSize
		validEnd = off
	}
	return overlay, validEnd
}
