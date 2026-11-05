package sitegen

import (
	"fmt"
	"strings"
)

const fence = "+++"

// splitFrontMatter splits a content file into its front matter text and its
// body. The file must start with "+++\n"; the front matter ends at the first
// later line that is exactly "+++", and the body is everything after that
// line's LF.
func splitFrontMatter(src string) (front, body string, err error) {
	if !strings.HasPrefix(src, fence+"\n") {
		return "", "", fmt.Errorf("content must begin with a %q front matter line", fence)
	}
	rest := src[len(fence)+1:]
	for pos := 0; ; {
		nl := strings.IndexByte(rest[pos:], '\n')
		if nl < 0 {
			if rest[pos:] == fence {
				return rest[:pos], "", nil
			}
			return "", "", fmt.Errorf("front matter is not closed by a %q line", fence)
		}
		if rest[pos:pos+nl] == fence {
			return rest[:pos], rest[pos+nl+1:], nil
		}
		pos += nl + 1
	}
}

// firstBlock returns the text of the first block of a Markdown body: the
// first maximal run of non-blank lines after any leading blank lines, joined
// with LF. A line is blank if it holds only spaces and tabs.
func firstBlock(body string) string {
	lines := strings.Split(body, "\n")
	i := 0
	for i < len(lines) && isBlankLine(lines[i]) {
		i++
	}
	j := i
	for j < len(lines) && !isBlankLine(lines[j]) {
		j++
	}
	return strings.Join(lines[i:j], "\n")
}

func isBlankLine(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' && s[i] != '\t' {
			return false
		}
	}
	return true
}
