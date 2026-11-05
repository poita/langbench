package session

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"kiln/build"
	"kiln/vfs"
)

// Run executes the script against fs and returns the session log. fs holds
// the final workspace afterwards.
func (sc *Script) Run(fs *vfs.FS) string {
	var log strings.Builder
	for i := range sc.Steps {
		runStep(&log, fs, i+1, &sc.Steps[i])
	}
	return log.String()
}

func runStep(log *strings.Builder, fs *vfs.FS, n int, st *Step) {
	log.WriteString("step ")
	log.WriteString(strconv.Itoa(n))
	log.WriteString(": ")
	switch st.Op {
	case OpBuild:
		log.WriteString("build")
		if len(st.Targets) == 0 {
			log.WriteString(" (default)")
		}
		for _, t := range st.Targets {
			log.WriteByte(' ')
			log.WriteString(t)
		}
		log.WriteString(" -j ")
		log.WriteString(strconv.Itoa(st.Workers))
		log.WriteByte('\n')
		writeBuild(log, build.Run(fs, build.Request{Targets: st.Targets, Workers: st.Workers}))
	case OpCreate, OpEdit:
		if st.Op == OpCreate {
			log.WriteString("create ")
		} else {
			log.WriteString("edit ")
		}
		log.WriteString(st.Path)
		log.WriteByte('\n')
		fs.Write(st.Path, st.Content)
		log.WriteString("  ok size=" + strconv.Itoa(len(st.Content)) + "\n")
	case OpDelete:
		log.WriteString("delete " + st.Path + "\n")
		fs.Delete(st.Path)
		log.WriteString("  ok\n")
	case OpTouch:
		log.WriteString("touch " + st.Path + "\n")
		fs.Touch(st.Path)
		log.WriteString("  ok\n")
	case OpClean:
		log.WriteString("clean\n")
		gone := fs.Generated()
		for _, p := range gone {
			log.WriteString("  remove " + p + "\n")
			fs.Delete(p)
		}
		log.WriteString("  ok removed=" + strconv.Itoa(len(gone)) + "\n")
	}
}

func writeBuild(log *strings.Builder, r *build.Result) {
	for _, e := range r.Events {
		log.WriteString("  ")
		log.WriteString(e.Kind.String())
		log.WriteByte(' ')
		if e.Kind == build.KindHit {
			log.WriteString(strconv.FormatInt(e.Start, 10))
			log.WriteByte(' ')
			log.WriteString(e.Target)
		} else {
			log.WriteString(strconv.FormatInt(e.Start, 10))
			log.WriteByte(' ')
			log.WriteString(strconv.FormatInt(e.End, 10))
			log.WriteString(" w")
			log.WriteString(strconv.Itoa(e.Worker))
			log.WriteByte(' ')
			log.WriteString(e.Target)
			log.WriteByte(' ')
			log.WriteString(e.Cmd)
		}
		log.WriteByte('\n')
	}
	if r.Err != nil {
		log.WriteString("  error " + r.Err.Error() + "\n")
		return
	}
	log.WriteString("  ok ran=" + strconv.Itoa(r.Ran) + " hit=" + strconv.Itoa(r.Hits) +
		" time=" + strconv.FormatInt(r.Time, 10) + "\n")
}

// RunDir runs the session found in inDir (session.txt plus the initial
// workspace) and writes log.txt and workspace/ into outDir.
func RunDir(inDir, outDir string) error {
	src, err := os.ReadFile(filepath.Join(inDir, "session.txt"))
	if err != nil {
		return err
	}
	script, err := Parse(src)
	if err != nil {
		return err
	}
	fs, err := vfs.LoadDir(inDir, "session.txt")
	if err != nil {
		return err
	}
	log := script.Run(fs)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outDir, "log.txt"), []byte(log), 0o644); err != nil {
		return err
	}
	return fs.WriteDir(filepath.Join(outDir, "workspace"))
}
