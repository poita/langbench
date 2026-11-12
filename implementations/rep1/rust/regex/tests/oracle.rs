//! Differential test: the VM against a direct, recursive transcription of the
//! continuation-passing definition of the matcher, on random patterns.

use btregex::ast::Node;
use btregex::parser::parse;
use btregex::Regex;

type Caps = Vec<Option<(usize, usize)>>;
type Cont<'a> = &'a mut dyn FnMut(usize, &mut Caps) -> bool;

fn m(node: &Node, s: &[u8], i: usize, caps: &mut Caps, k: Cont) -> bool {
    match node {
        Node::Char(c) => i < s.len() && s[i] == *c && k(i + 1, caps),
        Node::Any => i < s.len() && k(i + 1, caps),
        Node::Set(set) => i < s.len() && set.contains(s[i]) && k(i + 1, caps),
        Node::Bol => i == 0 && k(i, caps),
        Node::Eol => i == s.len() && k(i, caps),
        Node::Concat(v) => seq(v, s, i, caps, k),
        Node::Alt(bs) => {
            for b in bs {
                if m(b, s, i, caps, &mut *k) {
                    return true;
                }
            }
            false
        }
        Node::Group(g, x) => m(x, s, i, caps, &mut |j, caps: &mut Caps| {
            let old = caps[*g - 1];
            caps[*g - 1] = Some((i, j));
            if k(j, caps) {
                true
            } else {
                caps[*g - 1] = old;
                false
            }
        }),
        Node::Repeat { node, min, max } => {
            rep(node, *min, max.unwrap_or(u32::MAX), s, i, 0, caps, k)
        }
    }
}

fn seq(v: &[Node], s: &[u8], i: usize, caps: &mut Caps, k: Cont) -> bool {
    match v.split_first() {
        None => k(i, caps),
        Some((x, rest)) => m(x, s, i, caps, &mut |j, caps: &mut Caps| seq(rest, s, j, caps, &mut *k)),
    }
}

#[allow(clippy::too_many_arguments)]
fn rep(x: &Node, min: u32, max: u32, s: &[u8], i: usize, count: u32, caps: &mut Caps, k: Cont) -> bool {
    if count < min {
        return m(x, s, i, caps, &mut |j, caps: &mut Caps| rep(x, min, max, s, j, count + 1, caps, &mut *k));
    }
    if count == max {
        return k(i, caps);
    }
    if m(x, s, i, caps, &mut |j, caps: &mut Caps| {
        if j == i {
            k(j, caps)
        } else {
            rep(x, min, max, s, j, count + 1, caps, &mut *k)
        }
    }) {
        return true;
    }
    k(i, caps)
}

fn oracle(pattern: &str, subject: &str) -> Option<(usize, usize, Caps)> {
    let p = parse(pattern.as_bytes()).unwrap();
    let s = subject.as_bytes();
    for start in 0..=s.len() {
        let mut caps: Caps = vec![None; p.group_count];
        let mut end = None;
        if m(&p.node, s, start, &mut caps, &mut |j, _| {
            end = Some(j);
            true
        }) {
            return Some((start, end.unwrap(), caps));
        }
    }
    None
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn gen_alt(r: &mut Rng, depth: u32) -> String {
    let n = if r.below(4) == 0 { 2 + r.below(2) } else { 1 };
    (0..n).map(|_| gen_concat(r, depth)).collect::<Vec<_>>().join("|")
}

fn gen_concat(r: &mut Rng, depth: u32) -> String {
    let n = r.below(4);
    (0..n).map(|_| gen_piece(r, depth)).collect()
}

fn gen_piece(r: &mut Rng, depth: u32) -> String {
    if r.below(14) == 0 {
        return if r.below(2) == 0 { "^" } else { "$" }.to_string();
    }
    let atom = match r.below(if depth > 1 { 7 } else { 9 }) {
        0 | 1 => "a".to_string(),
        2 => "b".to_string(),
        3 => ".".to_string(),
        4 => "[ab]".to_string(),
        5 => "[^a]".to_string(),
        6 => "\\w".to_string(),
        _ => format!("({})", gen_alt(r, depth + 1)),
    };
    let q = match r.below(10) {
        0 => "*".to_string(),
        1 => "+".to_string(),
        2 => "?".to_string(),
        3 => {
            let a = r.below(3);
            format!("{{{},{}}}", a, a + r.below(3))
        }
        4 => format!("{{{},}}", r.below(3)),
        5 => format!("{{{}}}", r.below(4)),
        _ => String::new(),
    };
    atom + &q
}

fn gen_subject(r: &mut Rng) -> String {
    let n = r.below(7);
    (0..n).map(|_| ['a', 'b', 'c', 'a'][r.below(4) as usize]).collect()
}

#[test]
fn vm_agrees_with_reference_semantics() {
    let mut r = Rng(0x1234_5678_9abc_def0);
    let mut matched = 0;
    for _ in 0..8000 {
        let pattern = gen_alt(&mut r, 0);
        let re = Regex::new(&pattern).unwrap_or_else(|e| panic!("{pattern:?}: {e}"));
        for _ in 0..6 {
            let subject = gen_subject(&mut r);
            let got = re.find(&subject);
            let want = oracle(&pattern, &subject);
            match (&got, &want) {
                (None, None) => {}
                (Some(g), Some((s, e, caps))) => {
                    matched += 1;
                    assert_eq!((g.start(), g.end()), (*s, *e), "{pattern:?} on {subject:?}");
                    for (gi, c) in caps.iter().enumerate() {
                        assert_eq!(g.get(gi + 1), *c, "group {} of {pattern:?} on {subject:?}", gi + 1);
                    }
                }
                _ => panic!("{pattern:?} on {subject:?}: got {got:?}, want {want:?}"),
            }
        }
    }
    assert!(matched > 5000, "generator produced too few matches ({matched})");
}
