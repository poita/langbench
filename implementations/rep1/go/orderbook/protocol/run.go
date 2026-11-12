package protocol

import (
	"bufio"
	"bytes"
	"fmt"
	"io"

	"github.com/peteralexander/orderbook"
)

const (
	readBuf  = 1 << 20
	flushAt  = 1 << 16
	maxCount = 1 << 31
)

// Run reads a command stream from r, executes it against a fresh book and
// writes the resulting events to w. It stops after the number of commands
// announced on the first line (or at end of input, whichever comes first) and
// returns an error only for I/O failures or malformed input.
func Run(r io.Reader, w io.Writer) error {
	return RunBook(orderbook.New(), r, w)
}

// RunBook is like [Run] but executes the commands against book.
func RunBook(book *orderbook.Book, r io.Reader, w io.Writer) error {
	br := bufio.NewReaderSize(r, readBuf)
	out := make([]byte, 0, 2*flushAt)

	first, err := readLine(br)
	if err != nil && len(first) == 0 {
		if err == io.EOF {
			return nil // empty input: nothing to do
		}
		return err
	}
	n, ok := parseUint(first)
	if !ok || n > maxCount {
		return fmt.Errorf("%w: bad command count %q", ErrSyntax, first)
	}

	for i := uint64(0); i < n; i++ {
		line, err := readLine(br)
		if err != nil && len(line) == 0 {
			if err == io.EOF {
				break
			}
			return err
		}
		cmd, perr := ParseCommand(line)
		if perr != nil {
			return perr
		}
		for _, e := range book.Execute(cmd) {
			out = AppendEvent(out, e)
		}
		if len(out) >= flushAt {
			if _, err := w.Write(out); err != nil {
				return err
			}
			out = out[:0]
		}
	}
	_, err = w.Write(out)
	return err
}

// readLine returns the next line without its terminator. The slice is only
// valid until the next read. A final line without a newline is returned with a
// nil error; io.EOF is returned only when no bytes remain.
func readLine(br *bufio.Reader) ([]byte, error) {
	line, err := br.ReadSlice('\n')
	if err == bufio.ErrBufferFull {
		return nil, fmt.Errorf("%w: line too long", ErrSyntax)
	}
	line = bytes.TrimSuffix(line, []byte{'\n'})
	line = bytes.TrimSuffix(line, []byte{'\r'})
	if err == io.EOF && len(line) > 0 {
		err = nil
	}
	return line, err
}
