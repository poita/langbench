//! The `render.txt` job list and the directory-level driver.

use crate::error::Error;
use crate::render_svg;
use std::fs;
use std::path::Path;

/// One line of `render.txt`: an SVG file and the pixel size to render it at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Job {
    /// File name inside the input directory (ends in `.svg`).
    pub name: String,
    /// Output width in pixels.
    pub width: usize,
    /// Output height in pixels.
    pub height: usize,
}

impl Job {
    /// The output file name: `name` with `.svg` replaced by `.ppm`.
    pub fn output_name(&self) -> String {
        let stem = self.name.strip_suffix(".svg").unwrap_or(&self.name);
        format!("{stem}.ppm")
    }
}

/// Parses the text of a `render.txt` file.
///
/// Blank lines and lines whose first non-space character is `#` are
/// ignored; every other line must be `NAME WIDTH HEIGHT`.
pub fn parse_render_list(text: &str) -> Result<Vec<Job>, Error> {
    let mut jobs = Vec::new();
    for (i, raw) in text.split('\n').enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let bad = |reason: &str| Error::BadJobLine { line: i + 1, reason: reason.to_string() };
        let fields: Vec<&str> = t.split_whitespace().collect();
        if fields.len() != 3 {
            return Err(bad("expected NAME WIDTH HEIGHT"));
        }
        let dim = |s: &str| -> Result<usize, Error> {
            match s.parse::<usize>() {
                Ok(v) if (1..=4096).contains(&v) => Ok(v),
                _ => Err(bad("size must be an integer in 1..=4096")),
            }
        };
        jobs.push(Job { name: fields[0].to_string(), width: dim(fields[1])?, height: dim(fields[2])? });
    }
    Ok(jobs)
}

/// Renders every job listed in `<input_dir>/render.txt` into `output_dir`
/// (created if needed). All jobs are attempted; the failures are returned.
pub fn render_directory(input_dir: &Path, output_dir: &Path) -> Result<Vec<(String, Error)>, Error> {
    let list_path = input_dir.join("render.txt");
    let text = fs::read_to_string(&list_path)
        .map_err(|e| Error::Io(format!("cannot read {}: {e}", list_path.display())))?;
    let jobs = parse_render_list(&text)?;
    fs::create_dir_all(output_dir)
        .map_err(|e| Error::Io(format!("cannot create {}: {e}", output_dir.display())))?;
    let mut failures = Vec::new();
    for job in &jobs {
        if let Err(e) = render_job(job, input_dir, output_dir) {
            failures.push((job.name.clone(), e));
        }
    }
    Ok(failures)
}

fn render_job(job: &Job, input_dir: &Path, output_dir: &Path) -> Result<(), Error> {
    let src_path = input_dir.join(&job.name);
    let bytes = fs::read(&src_path).map_err(|e| Error::Io(format!("cannot read {}: {e}", src_path.display())))?;
    let src = String::from_utf8_lossy(&bytes);
    let canvas = render_svg(&src, job.width, job.height)?;
    let out_path = output_dir.join(job.output_name());
    fs::write(&out_path, canvas.to_ppm())
        .map_err(|e| Error::Io(format!("cannot write {}: {e}", out_path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_list_with_comments() {
        let jobs = parse_render_list("# c\n\n  \nlogo.svg 64 64\r\n  banner.svg   200 50\n").unwrap();
        assert_eq!(jobs.len(), 2);
        assert_eq!(jobs[1], Job { name: "banner.svg".into(), width: 200, height: 50 });
        assert_eq!(jobs[0].output_name(), "logo.ppm");
    }

    #[test]
    fn rejects_bad_lines() {
        assert!(parse_render_list("a.svg 1\n").is_err());
        assert!(parse_render_list("a.svg 0 5\n").is_err());
        assert!(parse_render_list("a.svg 5 4097\n").is_err());
    }
}
