package session

import (
	"bytes"
	"strconv"
	"strings"

	"buildsys/engine"
	"buildsys/sched"
	"buildsys/vfs"
)

// Run executes the session steps against fs and returns the log text. fs is
// left holding the final workspace.
func Run(fs *vfs.FS, steps []Step) []byte {
	var log bytes.Buffer
	for i, st := range steps {
		log.WriteString("step ")
		log.WriteString(strconv.Itoa(i + 1))
		log.WriteString(": ")
		switch st.Kind {
		case StepBuild:
			runBuild(&log, fs, st)
		case StepCreate, StepEdit:
			verb := "create"
			if st.Kind == StepEdit {
				verb = "edit"
			}
			log.WriteString(verb + " " + st.Path + "\n")
			fs.Write(st.Path, st.Content)
			log.WriteString("  ok size=" + strconv.Itoa(len(st.Content)) + "\n")
		case StepDelete:
			log.WriteString("delete " + st.Path + "\n")
			fs.Delete(st.Path)
			log.WriteString("  ok\n")
		case StepTouch:
			log.WriteString("touch " + st.Path + "\n")
			fs.Touch(st.Path)
			log.WriteString("  ok\n")
		case StepClean:
			log.WriteString("clean\n")
			removed := 0
			for _, p := range fs.Paths() {
				if p == vfs.StateFile || vfs.IsGenerated(p) {
					log.WriteString("  remove " + p + "\n")
					fs.Delete(p)
					removed++
				}
			}
			log.WriteString("  ok removed=" + strconv.Itoa(removed) + "\n")
		}
	}
	return log.Bytes()
}

// RunScript parses script (the text of session.txt) and runs it.
func RunScript(fs *vfs.FS, script []byte) ([]byte, error) {
	steps, err := ParseScript(script)
	if err != nil {
		return nil, err
	}
	return Run(fs, steps), nil
}

func runBuild(log *bytes.Buffer, fs *vfs.FS, st Step) {
	log.WriteString("build ")
	if len(st.Targets) == 0 {
		log.WriteString("(default)")
	} else {
		log.WriteString(strings.Join(st.Targets, " "))
	}
	log.WriteString(" -j " + strconv.Itoa(st.Jobs) + "\n")
	rep := engine.Build(fs, st.Targets, st.Jobs)
	for _, e := range rep.Events {
		log.WriteString("  ")
		s := e.Step
		if e.Kind == sched.KindHit {
			log.WriteString("hit " + strconv.FormatInt(e.Start, 10) + " " + s.Primary() + "\n")
			continue
		}
		verb := [...]string{sched.KindRun: "run", sched.KindFail: "fail", sched.KindCancel: "cancel"}[e.Kind]
		log.WriteString(verb + " " + strconv.FormatInt(e.Start, 10) + " " + strconv.FormatInt(e.End, 10) +
			" w" + strconv.Itoa(e.Worker) + " " + s.Primary() + " " + s.CmdString + "\n")
	}
	if rep.Err != nil {
		log.WriteString("  error " + rep.Err.Error() + "\n")
		return
	}
	log.WriteString("  ok ran=" + strconv.Itoa(rep.Ran) + " hit=" + strconv.Itoa(rep.Hits) +
		" time=" + strconv.FormatInt(rep.Time, 10) + "\n")
}
