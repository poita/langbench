package svgraster

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// RenderDir reads inDir/render.txt and renders every SVG file it lists into
// outDir as a binary PPM, creating outDir if necessary. A job that fails
// (for example an unreadable SVG file) does not stop the others; the errors
// are collected and returned together afterwards. The returned error is nil
// only if every job succeeded.
func RenderDir(inDir, outDir string) error {
	list, err := os.ReadFile(filepath.Join(inDir, "render.txt"))
	if err != nil {
		return err
	}
	jobs, err := ParseJobs(string(list))
	if err != nil {
		return fmt.Errorf("render.txt: %w", err)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	var failed []error
	for _, j := range jobs {
		if err := renderJob(inDir, outDir, j); err != nil {
			failed = append(failed, fmt.Errorf("%s: %w", j.Name, err))
		}
	}
	if len(failed) == 0 {
		return nil
	}
	return joinErrors(failed)
}

func renderJob(inDir, outDir string, j Job) error {
	src, err := os.ReadFile(filepath.Join(inDir, j.Name))
	if err != nil {
		return err
	}
	img, err := Render(src, j.Width, j.Height)
	if err != nil {
		return err
	}
	f, err := os.Create(filepath.Join(outDir, j.OutputName()))
	if err != nil {
		return err
	}
	if err := img.WritePPM(f); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func joinErrors(errs []error) error {
	return errors.Join(errs...)
}
