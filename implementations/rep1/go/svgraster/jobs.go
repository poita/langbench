package svgraster

import (
	"fmt"
	"strconv"
	"strings"
)

// Job is one line of a render list: render the SVG file Name at Width x
// Height pixels.
type Job struct {
	Name          string // file name, ending in ".svg"
	Width, Height int
}

// OutputName returns the output file name for the job: the name with ".svg"
// replaced by ".ppm".
func (j Job) OutputName() string {
	return strings.TrimSuffix(j.Name, ".svg") + ".ppm"
}

// ParseJobs parses the text of a render.txt file. Blank lines and lines
// whose first non-space character is '#' are ignored; every other line must
// be "NAME WIDTH HEIGHT". A trailing '\r' is stripped from each line.
func ParseJobs(text string) ([]Job, error) {
	var jobs []Job
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		f := strings.Fields(trimmed)
		if len(f) != 3 {
			return nil, fmt.Errorf("line %d: want NAME WIDTH HEIGHT, got %q", i+1, trimmed)
		}
		w, err1 := strconv.Atoi(f[1])
		h, err2 := strconv.Atoi(f[2])
		if err1 != nil || err2 != nil || w < 1 || h < 1 || w > MaxSize || h > MaxSize {
			return nil, fmt.Errorf("line %d: invalid size %q x %q", i+1, f[1], f[2])
		}
		jobs = append(jobs, Job{Name: f[0], Width: w, Height: h})
	}
	return jobs, nil
}
