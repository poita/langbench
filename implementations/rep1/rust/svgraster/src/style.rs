//! The `style` attribute: a list of `name: value` declarations.

/// Parsed declarations of one `style` attribute, in source order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Declarations(Vec<(String, String)>);

impl Declarations {
    /// Parses a `style` attribute value. Declarations without a `:` and
    /// declarations with an empty value are dropped; names are lower-cased.
    pub fn parse(s: &str) -> Declarations {
        let mut v = Vec::new();
        for decl in s.split(';') {
            let Some((name, value)) = decl.split_once(':') else { continue };
            let name = name.trim_matches(|c: char| c.is_ascii_whitespace()).to_ascii_lowercase();
            let value = value.trim_matches(|c: char| c.is_ascii_whitespace());
            if name.is_empty() || value.is_empty() {
                continue;
            }
            v.push((name, value.to_string()));
        }
        Declarations(v)
    }

    /// Returns the value of `name` (the last declaration wins).
    pub fn get(&self, name: &str) -> Option<&str> {
        self.0.iter().rev().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_declarations() {
        let d = Declarations::parse("fill : red ;; stroke:blue;bogus; opacity:;FILL-RULE:evenodd;");
        assert_eq!(d.get("fill"), Some("red"));
        assert_eq!(d.get("stroke"), Some("blue"));
        assert_eq!(d.get("opacity"), None);
        assert_eq!(d.get("fill-rule"), Some("evenodd"));
        assert_eq!(d.get("bogus"), None);
    }
}
