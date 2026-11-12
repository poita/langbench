// Package plan defines the build description produced by evaluating KBL build
// files: the steps, phony targets and default targets.
package plan

import "buildsys/cmds"

// Step is one build step.
type Step struct {
	Serial     int      // creation order across the whole build
	Outputs    []string // declared outputs; Outputs[0] is the primary output
	Depfile    string   // depfile path, or "" when there is none
	Inputs     []string // declared inputs, including "@phony" references
	After      []string // order-only dependencies
	FileInputs []string // the declared inputs that are not phony references
	Spec       *cmds.Spec
	Args       []cmds.Arg
	Command    string // canonical command string
	Cost       int
}

// Primary returns the step's primary output path.
func (s *Step) Primary() string { return s.Outputs[0] }

// AllOutputs returns the declared outputs followed by the depfile, if any.
func (s *Step) AllOutputs() []string {
	if s.Depfile == "" {
		return s.Outputs
	}
	out := make([]string, 0, len(s.Outputs)+1)
	out = append(out, s.Outputs...)
	return append(out, s.Depfile)
}

// Phony is a phony target; its dependencies are ordering-only.
type Phony struct {
	Name string // without the leading "@"
	Deps []string
}

// Plan is the result of evaluating a workspace's build files.
type Plan struct {
	Steps    []*Step
	Phonies  []*Phony // in declaration order
	Defaults []string

	phonyIndex map[string]*Phony
}

// FindPhony returns the phony target with the given name.
func (p *Plan) FindPhony(name string) *Phony { return p.phonyIndex[name] }

// AddPhony appends a phony target. It reports false, leaving the plan
// unchanged, if a phony target of that name already exists.
func (p *Plan) AddPhony(ph *Phony) bool {
	if _, dup := p.phonyIndex[ph.Name]; dup {
		return false
	}
	if p.phonyIndex == nil {
		p.phonyIndex = make(map[string]*Phony)
	}
	p.phonyIndex[ph.Name] = ph
	p.Phonies = append(p.Phonies, ph)
	return true
}
