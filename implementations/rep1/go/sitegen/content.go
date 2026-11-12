package sitegen

import (
	"fmt"
	"strings"

	"example.com/sitegen/toml"
)

// SplitFrontMatter splits a content file into its front matter text and its
// body. The file must begin with the line "+++"; the front matter ends at the
// next line that is exactly "+++", and the body is everything after that
// line, verbatim.
func SplitFrontMatter(src string) (front, body string, err error) {
	const open = "+++\n"
	if !strings.HasPrefix(src, open) {
		return "", "", fmt.Errorf("missing opening +++ line")
	}
	pos := len(open)
	for pos <= len(src) {
		end := strings.IndexByte(src[pos:], '\n')
		var line string
		next := len(src)
		if end >= 0 {
			line = src[pos : pos+end]
			next = pos + end + 1
		} else {
			line = src[pos:]
		}
		if line == "+++" {
			return src[len(open):pos], src[next:], nil
		}
		if end < 0 {
			break
		}
		pos = next
	}
	return "", "", fmt.Errorf("missing closing +++ line")
}

// excerptSource returns the first block of a body: after the leading blank
// lines, the following run of non-blank lines joined by LF. The rule is
// purely textual and knows nothing about Markdown structure.
func excerptSource(body string) string {
	rest := body
	var lines []string
	for len(rest) > 0 {
		var line string
		if i := strings.IndexByte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i+1:]
		} else {
			line, rest = rest, ""
		}
		blank := strings.Trim(line, " \t") == ""
		if blank {
			if len(lines) > 0 {
				break
			}
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// parsed content file common fields.
type contentFile struct {
	doc   *toml.Document
	body  string
	slug  string
	title string
	draft bool
}

func parseContent(name, src string) (*contentFile, error) {
	front, body, err := SplitFrontMatter(src)
	if err != nil {
		return nil, err
	}
	doc, err := toml.Parse(front)
	if err != nil {
		return nil, err
	}
	cf := &contentFile{doc: doc, body: body}
	var ok bool
	if cf.title, ok = doc.String("title"); !ok {
		return nil, fmt.Errorf("missing string key \"title\"")
	}
	cf.slug = strings.TrimSuffix(name, ".md")
	if v, present := doc.Get("slug"); present {
		if v.Kind != toml.String {
			return nil, fmt.Errorf("\"slug\" must be a string")
		}
		cf.slug = v.Str
	}
	if v, present := doc.Get("draft"); present {
		if v.Kind != toml.Boolean {
			return nil, fmt.Errorf("\"draft\" must be a boolean")
		}
		cf.draft = v.Bool
	}
	return cf, nil
}
