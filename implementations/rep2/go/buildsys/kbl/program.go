package kbl

import (
	"kiln/cmds"
	"kiln/vfs"
)

// MainFile is the workspace path of the root build file.
const MainFile = "main.kiln"

// Step is one build step produced by evaluating a build file.
type Step struct {
	Serial  int      // creation order across the whole build
	Outs    []string // declared outputs; Outs[0] is the primary output
	Depfile string   // "" when the step has none
	Ins     []string // declared inputs, including "@phony" references
	After   []string // order-only dependencies
	Spec    *cmds.Spec
	Args    []cmds.Arg
	Cost    int64
	CmdStr  string   // canonical command string
	FileIns []string // Ins without the phony references: the hashed dependencies
}

// Primary returns the step's primary output path.
func (s *Step) Primary() string { return s.Outs[0] }

// FullOutputs returns the declared outputs followed by the depfile.
func (s *Step) FullOutputs() []string {
	if s.Depfile == "" {
		return s.Outs
	}
	out := make([]string, 0, len(s.Outs)+1)
	out = append(out, s.Outs...)
	return append(out, s.Depfile)
}

// Phony is a phony target; its dependencies are ordering-only.
type Phony struct {
	Name string // without the leading "@"
	Deps []string
}

// Program is the result of evaluating a workspace's build files.
type Program struct {
	Steps    []*Step
	Phonies  []*Phony // in declaration order
	Defaults []string // the default target list, duplicates kept
}

// CheckRef validates the shape of a reference used in "in", "after" or a
// phony dependency list: "@" followed by an identifier-shaped name, or a
// workspace path.
func CheckRef(s string) bool {
	if len(s) > 0 && s[0] == '@' {
		return vfs.IsIdent(s[1:])
	}
	return vfs.ValidPath(s)
}
