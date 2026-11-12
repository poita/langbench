// Package source splits the raw input into its module stream (SPEC.md
// section 2).
package source

import (
	"strings"

	"langvm/diag"
)

// Module is one module of the stream.
type Module struct {
	Name  string
	Lines []string // body lines, header excluded, CR before LF removed
}

// Keywords of the language; an identifier may not be one of them.
var keywords = map[string]bool{
	"as": true, "break": true, "continue": true, "else": true, "enum": true,
	"false": true, "fn": true, "for": true, "if": true, "impl": true,
	"in": true, "let": true, "match": true, "pub": true, "return": true,
	"self": true, "struct": true, "trait": true, "true": true, "use": true,
	"var": true, "when": true, "while": true,
}

// IsKeyword reports whether s is a reserved word.
func IsKeyword(s string) bool { return keywords[s] }

// IsIdent reports whether s is a legal identifier (section 3.3).
func IsIdent(s string) bool {
	if s == "" || s == "_" || len(s) > 200 || keywords[s] {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(i > 0 && c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

func splitLines(input string) []string {
	if input == "" {
		return nil
	}
	lines := strings.Split(input, "\n")
	terminated := lines[len(lines)-1] == ""
	if terminated {
		lines = lines[:len(lines)-1]
	}
	for i, l := range lines {
		// A CR is dropped only when it directly precedes an LF.
		if i < len(lines)-1 || terminated {
			lines[i] = strings.TrimSuffix(l, "\r")
		}
	}
	return lines
}

// headerName returns the module name if line is a module header.
func headerName(line string) (string, bool) {
	const prefix = "@module "
	if !strings.HasPrefix(line, prefix) {
		return "", false
	}
	name := line[len(prefix):]
	if !IsIdent(name) {
		return "", false
	}
	return name, true
}

// Split divides input into modules. It reports bad-module and dup-module
// diagnostics, which use whole-input line numbers.
func Split(input string) ([]*Module, *diag.Error) {
	lines := splitLines(input)
	if len(lines) == 0 {
		return nil, diag.New(diag.BadModule, diag.Pos{Line: 1, Col: 1})
	}
	var mods []*Module
	var headerLines []int
	var cur *Module
	for i, l := range lines {
		if name, ok := headerName(l); ok {
			cur = &Module{Name: name}
			mods = append(mods, cur)
			headerLines = append(headerLines, i+1)
			continue
		}
		if i == 0 || strings.HasPrefix(l, "@") {
			return nil, diag.New(diag.BadModule, diag.Pos{Line: i + 1, Col: 1})
		}
		cur.Lines = append(cur.Lines, l)
	}
	seen := map[string]bool{}
	for i, m := range mods {
		if seen[m.Name] {
			return nil, diag.New(diag.DupModule, diag.Pos{Line: headerLines[i], Col: 1})
		}
		seen[m.Name] = true
	}
	return mods, nil
}
