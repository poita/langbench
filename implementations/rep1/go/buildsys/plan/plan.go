// Package plan defines the build description produced by evaluating Kiln
// build files: steps, phony targets and the default target list.
package plan

import "buildsys/command"

// Step is one build step.
type Step struct {
	Serial  int      // order of creation across the whole build
	Outs    []string // declared outputs; Outs[0] is the primary output
	Ins     []string // declared inputs, including "@phony" references
	After   []string // order-only dependencies
	Depfile string   // depfile path, or "" if none
	Cmd     string   // command name
	Args    []command.Arg
	Cost    int64

	FileIns   []string // declared inputs that are not phony references
	FullOuts  []string // Outs followed by Depfile (if any)
	CmdString string   // canonical command string
}

// Primary returns the step's primary output path.
func (s *Step) Primary() string { return s.Outs[0] }

// Phony is a phony target; its dependencies are ordering-only.
type Phony struct {
	Name string // without the leading "@"
	Deps []string
}

// Plan is the result of evaluating a workspace's build files.
type Plan struct {
	Steps    []*Step
	Phonies  []*Phony // in declaration order
	Defaults []string // the default target list, duplicates kept
}
