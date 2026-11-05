package inflate

import "errors"

// Errors returned for malformed streams. They are sentinel values and can be
// matched with errors.Is.
var (
	// ErrTruncated: the stream ended before the final block was complete.
	ErrTruncated = errors.New("inflate: unexpected end of stream")
	// ErrBlockType: a block header used the reserved BTYPE value 3.
	ErrBlockType = errors.New("inflate: invalid block type")
	// ErrStoredLength: a stored block's NLEN is not the complement of LEN.
	ErrStoredLength = errors.New("inflate: stored block length check failed")
	// ErrTooManyCodes: HLIT or HDIST exceeds the permitted alphabet size.
	ErrTooManyCodes = errors.New("inflate: too many length or distance codes")
	// ErrOverSubscribed: a set of code lengths over-subscribes the code space.
	ErrOverSubscribed = errors.New("inflate: over-subscribed Huffman code")
	// ErrIncompleteCode: a set of code lengths leaves code space unused where
	// that is not permitted.
	ErrIncompleteCode = errors.New("inflate: incomplete Huffman code")
	// ErrMissingEndOfBlock: the literal/length code has no end-of-block symbol.
	ErrMissingEndOfBlock = errors.New("inflate: no end-of-block code")
	// ErrBadRepeat: a code-length repeat has no previous length or overflows
	// the number of lengths.
	ErrBadRepeat = errors.New("inflate: invalid code length repeat")
	// ErrInvalidCode: a bit pattern matched no code in an incomplete table.
	ErrInvalidCode = errors.New("inflate: invalid Huffman code")
	// ErrInvalidSymbol: a reserved symbol (literal/length 286, 287 or
	// distance 30, 31) was decoded.
	ErrInvalidSymbol = errors.New("inflate: invalid symbol")
	// ErrDistance: a back-reference reaches before the start of the output.
	ErrDistance = errors.New("inflate: distance too far back")
	// ErrTrailingData: whole bytes remain after the final block.
	ErrTrailingData = errors.New("inflate: trailing data after final block")
)
