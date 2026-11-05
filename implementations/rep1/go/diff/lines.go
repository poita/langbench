package linediff

import "bytes"

// SplitLines splits text into lines without their terminating "\n". The
// returned slices are views into text, not copies. A final line that lacks a
// terminator is still returned; text ending in "\n" does not produce a
// trailing empty line. Empty text yields no lines.
func SplitLines(text []byte) [][]byte {
	if len(text) == 0 {
		return nil
	}
	lines := make([][]byte, 0, bytes.Count(text, []byte{'\n'})+1)
	for len(text) > 0 {
		i := bytes.IndexByte(text, '\n')
		if i < 0 {
			lines = append(lines, text)
			break
		}
		lines = append(lines, text[:i])
		text = text[i+1:]
	}
	return lines
}
