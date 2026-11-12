//! Differential test: random command sequences are run through the real
//! `Buffer` and through a deliberately naive model that follows the
//! specification literally, working on one flat string with character
//! offsets. The two must print identical output.

use textbuffer::script;

/// Small deterministic generator (xorshift64*), so failures are reproducible.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

// ---- the naive model (offsets into one string) -----------------------------

#[derive(Clone, Debug)]
struct MCursor {
    head: usize,
    anchor: Option<usize>,
    primary: bool,
    goal: usize,
}

impl MCursor {
    fn range(&self) -> (usize, usize) {
        match self.anchor {
            Some(a) => (a.min(self.head), a.max(self.head)),
            None => (self.head, self.head),
        }
    }
}

struct Entry {
    before: Vec<MCursor>,
    after: Vec<MCursor>,
    repls: Vec<(usize, String, String)>, // offset, removed, inserted
}

struct Model {
    text: String,
    cursors: Vec<MCursor>,
    undo: Vec<Entry>,
    redo: Vec<Entry>,
    out: String,
}

impl Model {
    fn new(lines: &[String]) -> Model {
        Model {
            text: lines.join("\n"),
            cursors: vec![MCursor {
                head: 0,
                anchor: None,
                primary: true,
                goal: 0,
            }],
            undo: vec![],
            redo: vec![],
            out: String::new(),
        }
    }

    fn lines(&self) -> Vec<&str> {
        self.text.split('\n').collect()
    }

    /// (line, col) of an offset.
    fn lc(&self, off: usize) -> (usize, usize) {
        let mut rest = off;
        for (i, l) in self.lines().iter().enumerate() {
            if rest <= l.len() {
                return (i, rest);
            }
            rest -= l.len() + 1;
        }
        unreachable!()
    }

    fn offset(&self, line: usize, col: usize) -> usize {
        self.lines()[..line]
            .iter()
            .map(|l| l.len() + 1)
            .sum::<usize>()
            + col
    }

    fn clamp(&self, line: usize, col: usize) -> usize {
        let n = self.lines().len();
        let line = line.min(n - 1);
        let col = col.min(self.lines()[line].len());
        self.offset(line, col)
    }

    fn normalize(&mut self) {
        let mut cs = std::mem::take(&mut self.cursors);
        cs.sort_by_key(|c| (c.range().0, std::cmp::Reverse(c.range().1)));
        let mut out: Vec<MCursor> = vec![];
        for c in cs {
            if let Some(cur) = out.last_mut() {
                let (cs_, ce) = c.range();
                let (gs, ge) = cur.range();
                let join = if cur.anchor.is_none() || c.anchor.is_none() {
                    cs_ <= ge
                } else {
                    cs_ < ge
                };
                if join {
                    let end = ge.max(ce);
                    let backward = matches!(cur.anchor, Some(a) if cur.head < a);
                    if gs == end {
                        cur.head = gs;
                        cur.anchor = None;
                    } else if backward {
                        cur.head = gs;
                        cur.anchor = Some(end);
                    } else {
                        cur.head = end;
                        cur.anchor = Some(gs);
                    }
                    cur.primary |= c.primary;
                    continue;
                }
            }
            out.push(c);
        }
        self.cursors = out;
    }

    fn reset_goals(&mut self) {
        let heads: Vec<usize> = self.cursors.iter().map(|c| self.lc(c.head).1).collect();
        for (c, g) in self.cursors.iter_mut().zip(heads) {
            c.goal = g;
        }
    }

    fn edit(&mut self, kind: char, ins: &str) {
        let before = self.cursors.clone();
        let mut cs = self.cursors.clone();
        let mut repls = vec![];
        for i in 0..cs.len() {
            let (mut s, mut e) = cs[i].range();
            if cs[i].anchor.is_none() {
                match kind {
                    'd' if s > 0 => s -= 1,
                    'f' if e < self.text.len() => e += 1,
                    'i' => {}
                    _ => continue,
                }
            }
            let t = if kind == 'i' { ins } else { "" };
            let removed = self.text[s..e].to_string();
            if removed.is_empty() && t.is_empty() {
                continue;
            }
            self.text.replace_range(s..e, t);
            repls.push((s, removed, t.to_string()));
            let m = t.len();
            cs[i].head = s + m;
            cs[i].anchor = None;
            for c in cs.iter_mut().skip(i + 1) {
                c.head = c.head - e + s + m;
                c.anchor = c.anchor.map(|a| a - e + s + m);
            }
        }
        self.cursors = cs;
        self.normalize();
        self.reset_goals();
        if !repls.is_empty() {
            self.undo.push(Entry {
                before,
                after: self.cursors.clone(),
                repls,
            });
            self.redo.clear();
        }
    }

    fn mv(&mut self, dir: &str, select: bool) {
        let lines: Vec<String> = self.lines().iter().map(|s| s.to_string()).collect();
        let n = lines.len();
        let mut cs = std::mem::take(&mut self.cursors);
        for c in cs.iter_mut() {
            let (s, e) = c.range();
            if !select {
                if c.anchor.is_some() && (dir == "left" || dir == "right") {
                    c.head = if dir == "left" { s } else { e };
                    c.anchor = None;
                    continue;
                }
                c.anchor = None;
            } else if c.anchor.is_none() {
                c.anchor = Some(c.head);
            }
            let (l, col) = self.lc(c.head);
            let (nl, nc) = match dir {
                "left" if col > 0 => (l, col - 1),
                "left" if l > 0 => (l - 1, lines[l - 1].len()),
                "left" => (l, col),
                "right" if col < lines[l].len() => (l, col + 1),
                "right" if l + 1 < n => (l + 1, 0),
                "right" => (l, col),
                "home" => (l, 0),
                "end" => (l, lines[l].len()),
                "up" if l == 0 => {
                    c.goal = 0;
                    (0, 0)
                }
                "up" => (l - 1, c.goal.min(lines[l - 1].len())),
                "down" if l == n - 1 => {
                    c.goal = lines[l].len();
                    (l, lines[l].len())
                }
                "down" => (l + 1, c.goal.min(lines[l + 1].len())),
                _ => unreachable!(),
            };
            c.head = self.offset(nl, nc);
            if c.anchor == Some(c.head) {
                c.anchor = None;
            }
        }
        self.cursors = cs;
        self.normalize();
        if dir != "up" && dir != "down" {
            self.reset_goals();
        }
    }

    fn command(&mut self, line: &str) {
        let (word, rest) = line.split_once(' ').unwrap_or((line, ""));
        match word {
            "insert" => {
                let mut t = String::new();
                let mut it = rest.chars();
                while let Some(c) = it.next() {
                    if c == '\\' {
                        t.push(if it.next() == Some('n') { '\n' } else { '\\' });
                    } else {
                        t.push(c);
                    }
                }
                self.edit('i', &t);
            }
            "delete" => self.edit('d', ""),
            "delete-forward" => self.edit('f', ""),
            "move" => {
                let mut w = rest.split(' ');
                let d = w.next().unwrap();
                self.mv(d, w.next().is_some());
            }
            "goto" | "add-cursor" => {
                let mut w = rest.split(' ').map(|x| x.parse::<usize>().unwrap());
                let h = self.clamp(w.next().unwrap(), w.next().unwrap());
                if word == "goto" {
                    self.cursors = vec![MCursor {
                        head: h,
                        anchor: None,
                        primary: true,
                        goal: 0,
                    }];
                } else {
                    self.cursors.push(MCursor {
                        head: h,
                        anchor: None,
                        primary: false,
                        goal: 0,
                    });
                }
                self.normalize();
                self.reset_goals();
            }
            "clear-cursors" => {
                self.cursors.retain(|c| c.primary);
                self.normalize();
                self.reset_goals();
            }
            "undo" => {
                if let Some(e) = self.undo.pop() {
                    for (s, removed, ins) in e.repls.iter().rev() {
                        self.text.replace_range(*s..*s + ins.len(), removed);
                    }
                    self.cursors = e.before.clone();
                    self.redo.push(e);
                }
                self.reset_goals();
            }
            "redo" => {
                if let Some(e) = self.redo.pop() {
                    for (s, removed, ins) in e.repls.iter() {
                        self.text.replace_range(*s..*s + removed.len(), ins);
                    }
                    self.cursors = e.after.clone();
                    self.undo.push(e);
                }
                self.reset_goals();
            }
            "print" => {
                self.out.push_str(&self.text);
                self.out.push('\n');
                for c in &self.cursors {
                    let (l, col) = self.lc(c.head);
                    self.out.push_str(&format!("cursor {l} {col}\n"));
                }
                self.out.push_str("--\n");
            }
            _ => panic!("bad command {line}"),
        }
    }
}

// ---- generator --------------------------------------------------------------

const ALPHABET: &[u8] = b"abc XY\\!";

fn random_text(rng: &mut Rng, max: usize) -> String {
    let n = 1 + rng.below(max);
    let mut s = String::new();
    for _ in 0..n {
        match rng.below(8) {
            0 => s.push_str("\\n"),
            1 => s.push_str("\\\\"),
            _ => s.push(
                *[b'a', b'b', b'c', b' ', b'X', b'!']
                    .get(rng.below(6))
                    .unwrap() as char,
            ),
        }
    }
    s
}

fn random_script(
    seed: u64,
    commands: usize,
    max_cursors_bias: usize,
) -> (String, Vec<String>, Vec<String>) {
    let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
    let n = rng.below(6);
    let doc: Vec<String> = (0..n)
        .map(|_| {
            (0..rng.below(8))
                .map(|_| ALPHABET[rng.below(ALPHABET.len())] as char)
                .collect()
        })
        .collect();
    let mut cmds = vec![];
    for _ in 0..commands {
        let pos = |rng: &mut Rng| {
            let big = rng.below(10) == 0;
            let b = if big { 1_000_000_000 } else { 8 };
            format!("{} {}", rng.below(b.min(8) + 1), rng.below(b + 1))
        };
        let c = match rng.below(40) {
            0..=7 => format!("insert {}", random_text(&mut rng, 4)),
            8..=11 => "delete".to_string(),
            12..=14 => "delete-forward".to_string(),
            15..=24 => {
                let d = ["left", "right", "up", "down", "home", "end"][rng.below(6)];
                if rng.below(2) == 0 {
                    format!("move {d} select")
                } else {
                    format!("move {d}")
                }
            }
            25..=27 => format!("goto {}", pos(&mut rng)),
            28..=33 if max_cursors_bias > 0 => format!("add-cursor {}", pos(&mut rng)),
            28..=33 => format!("goto {}", pos(&mut rng)),
            34 => "clear-cursors".to_string(),
            35..=36 => "undo".to_string(),
            37 => "redo".to_string(),
            _ => "print".to_string(),
        };
        cmds.push(c);
    }
    cmds.push("print".to_string());
    let mut input = format!("{}\n", doc.len());
    for l in &doc {
        input.push_str(l);
        input.push('\n');
    }
    for c in &cmds {
        input.push_str(c);
        input.push('\n');
    }
    (input, doc, cmds)
}

fn check(seed: u64, commands: usize, bias: usize) {
    let (input, doc, cmds) = random_script(seed, commands, bias);
    let mut model = Model::new(&doc);
    for c in &cmds {
        model.command(c);
    }
    let mut out = Vec::new();
    script::run(input.as_bytes(), &mut out).unwrap();
    let out = String::from_utf8(out).unwrap();
    if out != model.out {
        let (a, b): (Vec<_>, Vec<_>) = (out.lines().collect(), model.out.lines().collect());
        let i = a
            .iter()
            .zip(&b)
            .position(|(x, y)| x != y)
            .unwrap_or(a.len().min(b.len()));
        panic!(
            "seed {seed}: outputs differ at output line {i}: {:?} vs model {:?}\n{input}",
            a.get(i),
            b.get(i)
        );
    }
}

#[test]
fn single_cursor_scripts_match_the_model() {
    for seed in 0..300 {
        check(seed, 150, 0);
    }
}

#[test]
fn multi_cursor_scripts_match_the_model() {
    for seed in 1000..1600 {
        check(seed, 150, 1);
    }
}
