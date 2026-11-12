package inflate

import "errors"

// Errors returned by the decoder. They are sentinel values and can be
// compared with errors.Is.
var (
	// ErrTruncated means the stream ended before the final block was complete.
	ErrTruncated = errors.New("inflate: unexpected end of stream")
	// ErrBlockType means a block header had the reserved type 3.
	ErrBlockType = errors.New("inflate: invalid block type")
	// ErrStoredLength means a stored block's LEN and NLEN are not complements.
	ErrStoredLength = errors.New("inflate: stored block length check failed")
	// ErrHeaderCounts means HLIT or HDIST of a dynamic block is out of range.
	ErrHeaderCounts = errors.New("inflate: too many literal/length or distance codes")
	// ErrCodeLengths means a set of Huffman code lengths is not acceptable:
	// over-subscribed, incomplete, or missing the end-of-block code.
	ErrCodeLengths = errors.New("inflate: invalid Huffman code lengths")
	// ErrRepeat means a code-length repeat had no previous length to copy or
	// overflowed the number of lengths being read.
	ErrRepeat = errors.New("inflate: invalid code length repeat")
	// ErrInvalidCode means the input bits do not match any code of an
	// incomplete Huffman table.
	ErrInvalidCode = errors.New("inflate: invalid Huffman code")
	// ErrInvalidSymbol means a symbol that must not occur was decoded: a
	// literal/length symbol 286 or 287, a distance symbol 30 or 31.
	ErrInvalidSymbol = errors.New("inflate: invalid symbol")
	// ErrDistance means a back-reference reaches before the start of the
	// output.
	ErrDistance = errors.New("inflate: distance too far back")
	// ErrTrailingData means whole bytes remain after the final block.
	ErrTrailingData = errors.New("inflate: trailing data after final block")
)
