//! Applying an edit script.

use crate::edit::{ScriptLine, Tag};
use crate::error::Error;

/// Applies `script` to `a` and returns the resulting sequence.
///
/// The script's `Keep` and `Delete` lines, in order, must be exactly `a`;
/// otherwise an [`Error::Patch`] is returned. The script need not be minimal.
///
/// Runs in O(N + K).
pub fn patch<T: Clone + PartialEq>(a: &[T], script: &[ScriptLine<T>]) -> Result<Vec<T>, Error> {
    let mut out = Vec::with_capacity(script.len());
    let mut next = 0usize;
    for (n, line) in script.iter().enumerate() {
        match line.tag {
            Tag::Insert => out.push(line.text.clone()),
            Tag::Keep | Tag::Delete => {
                let Some(orig) = a.get(next) else {
                    return Err(Error::Patch(format!(
                        "script line {} consumes more lines than the file has",
                        n + 1
                    )));
                };
                if *orig != line.text {
                    return Err(Error::Patch(format!(
                        "script line {} does not match line {} of the file",
                        n + 1,
                        next + 1
                    )));
                }
                next += 1;
                if line.tag == Tag::Keep {
                    out.push(line.text.clone());
                }
            }
        }
    }
    if next != a.len() {
        return Err(Error::Patch(format!(
            "script consumes {} of {} lines of the file",
            next,
            a.len()
        )));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn l(tag: Tag, text: &'static str) -> ScriptLine<&'static str> {
        ScriptLine { tag, text }
    }

    #[test]
    fn applies_non_minimal_script() {
        let a = ["a", "b"];
        let s = [
            l(Tag::Delete, "a"),
            l(Tag::Insert, "a"),
            l(Tag::Keep, "b"),
            l(Tag::Insert, ""),
        ];
        assert_eq!(patch(&a, &s).unwrap(), vec!["a", "b", ""]);
    }

    #[test]
    fn rejects_mismatch_and_short_scripts() {
        let a = ["a", "b"];
        assert!(patch(&a, &[l(Tag::Keep, "x"), l(Tag::Keep, "b")]).is_err());
        assert!(patch(&a, &[l(Tag::Keep, "a")]).is_err());
        assert!(patch(&a, &[l(Tag::Keep, "a"), l(Tag::Keep, "b"), l(Tag::Keep, "c")]).is_err());
    }
}
