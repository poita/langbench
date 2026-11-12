//! The stdin framing: a JSON context, a `--` line, then `=== name` templates.

use crate::error::{Error, Result};

/// The parsed framing of the program input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Input {
    /// The JSON text before the `--` line.
    pub context: String,
    /// The templates in order of appearance as `(name, body)`; the first one
    /// is the one rendered.
    pub templates: Vec<(String, String)>,
}

/// Splits program input into the JSON context and the named templates.
///
/// A template body runs from the line after its `=== name` header up to the
/// LF that precedes the next header (that LF is not part of the body); the
/// last body ends at the end of input minus one trailing LF.
pub fn split(input: &str) -> Result<Input> {
    // The JSON document ends at the first line that is exactly `--`.
    let mut offset = 0;
    let mut sep = None;
    for line in input.split_inclusive('\n') {
        if line.strip_suffix('\n').unwrap_or(line) == "--" {
            sep = Some((offset, offset + line.len()));
            break;
        }
        offset += line.len();
    }
    let (json_end, rest_start) = sep.ok_or_else(|| Error::syntax("missing '--' separator line"))?;
    let context = input[..json_end].to_string();
    let rest = &input[rest_start..];

    // Locate header lines.
    let mut headers: Vec<(usize, usize, &str)> = Vec::new(); // (line start, body start, name)
    let mut off = 0;
    for line in rest.split_inclusive('\n') {
        if let Some(name) = line.strip_prefix("=== ") {
            headers.push((off, off + line.len(), name.strip_suffix('\n').unwrap_or(name)));
        }
        off += line.len();
    }
    let mut templates = Vec::with_capacity(headers.len());
    for (i, &(_, body_start, name)) in headers.iter().enumerate() {
        let body = match headers.get(i + 1) {
            Some(&(next_line, _, _)) => {
                let end = if next_line > body_start { next_line - 1 } else { next_line };
                &rest[body_start..end]
            }
            None => {
                let b = &rest[body_start..];
                b.strip_suffix('\n').unwrap_or(b)
            }
        };
        templates.push((name.to_string(), body.to_string()));
    }
    if templates.is_empty() {
        return Err(Error::syntax("no templates in input"));
    }
    Ok(Input { context, templates })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_context_and_templates() {
        let i = split("{\"a\": 1}\n--\n=== main\nHello\n\n=== other\nx\ny\n").unwrap();
        assert_eq!(i.context, "{\"a\": 1}\n");
        assert_eq!(i.templates[0], ("main".into(), "Hello\n".into()));
        assert_eq!(i.templates[1], ("other".into(), "x\ny".into()));
    }

    #[test]
    fn empty_bodies() {
        let i = split("{}\n--\n=== a\n=== b\n\n").unwrap();
        assert_eq!(i.templates, vec![("a".into(), "".into()), ("b".into(), "".into())]);
    }

    #[test]
    fn multiline_json() {
        let i = split("{\n\"a\": 1\n}\n--\n=== m\nx").unwrap();
        assert_eq!(i.context, "{\n\"a\": 1\n}\n");
        assert_eq!(i.templates[0].1, "x");
    }

    #[test]
    fn missing_separator_is_error() {
        assert!(split("{}\n").is_err());
    }
}
