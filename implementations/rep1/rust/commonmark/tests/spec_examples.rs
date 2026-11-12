//! Runs the examples of the CommonMark 0.31.2 specification that fall inside
//! the supported subset (`tests/data/spec_examples.json`: the examples without
//! raw HTML, link reference definitions or named entities).

/// A minimal JSON reader, enough for an array of flat objects whose values are
/// strings or integers (the tests may not use external crates).
struct Json<'a> {
    s: &'a [u8],
    i: usize,
}

#[derive(Debug)]
struct Example {
    n: u32,
    md: String,
    html: String,
}

impl<'a> Json<'a> {
    fn ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }
    fn expect(&mut self, c: u8) {
        self.ws();
        assert_eq!(self.s[self.i], c, "unexpected byte at {}", self.i);
        self.i += 1;
    }
    fn string(&mut self) -> String {
        self.expect(b'"');
        let mut out = String::new();
        loop {
            let b = self.s[self.i];
            self.i += 1;
            match b {
                b'"' => return out,
                b'\\' => {
                    let e = self.s[self.i];
                    self.i += 1;
                    match e {
                        b'n' => out.push('\n'),
                        b't' => out.push('\t'),
                        b'r' => out.push('\r'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'u' => {
                            let hex = |j: &mut Json| {
                                let h = std::str::from_utf8(&j.s[j.i..j.i + 4]).unwrap();
                                j.i += 4;
                                u32::from_str_radix(h, 16).unwrap()
                            };
                            let mut cp = hex(self);
                            if (0xD800..0xDC00).contains(&cp) {
                                assert_eq!(&self.s[self.i..self.i + 2], b"\\u");
                                self.i += 2;
                                let lo = hex(self);
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            }
                            out.push(char::from_u32(cp).unwrap());
                        }
                        other => out.push(other as char),
                    }
                }
                _ => {
                    // Copy a whole UTF-8 sequence.
                    let start = self.i - 1;
                    let mut end = self.i;
                    while end < self.s.len() && (self.s[end] & 0xC0) == 0x80 {
                        end += 1;
                    }
                    out.push_str(std::str::from_utf8(&self.s[start..end]).unwrap());
                    self.i = end;
                }
            }
        }
    }
    fn examples(&mut self) -> Vec<Example> {
        let mut v = Vec::new();
        self.expect(b'[');
        loop {
            self.ws();
            if self.s[self.i] == b']' {
                break;
            }
            if self.s[self.i] == b',' {
                self.i += 1;
                continue;
            }
            self.expect(b'{');
            let (mut n, mut md, mut html) = (0, String::new(), String::new());
            loop {
                self.ws();
                if self.s[self.i] == b'}' {
                    self.i += 1;
                    break;
                }
                if self.s[self.i] == b',' {
                    self.i += 1;
                    continue;
                }
                let key = self.string();
                self.expect(b':');
                self.ws();
                if self.s[self.i] == b'"' {
                    let val = self.string();
                    match key.as_str() {
                        "md" => md = val,
                        "html" => html = val,
                        _ => {}
                    }
                } else {
                    let start = self.i;
                    while self.s[self.i].is_ascii_digit() {
                        self.i += 1;
                    }
                    if key == "n" {
                        n = std::str::from_utf8(&self.s[start..self.i]).unwrap().parse().unwrap();
                    }
                }
            }
            v.push(Example { n, md, html });
        }
        v
    }
}

#[test]
fn spec_examples() {
    let data = include_str!("data/spec_examples.json");
    let examples = Json { s: data.as_bytes(), i: 0 }.examples();
    assert!(examples.len() > 400);
    let mut failures = Vec::new();
    for e in &examples {
        let got = commonmark::to_html(&e.md);
        if got != e.html {
            failures.push(format!("example {}:\n--- markdown\n{}\n--- expected\n{}\n--- got\n{}", e.n, e.md, e.html, got));
        }
    }
    assert!(failures.is_empty(), "{} failing examples:\n{}", failures.len(), failures.join("\n=====\n"));
}
