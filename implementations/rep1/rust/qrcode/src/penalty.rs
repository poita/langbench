//! Mask penalty scoring (N1..N4) on a complete symbol.

use crate::matrix::Matrix;

const FINDER_LIKE_A: [bool; 11] = [
    true, false, true, true, true, false, true, false, false, false, false,
];
const FINDER_LIKE_B: [bool; 11] = [
    false, false, false, false, true, false, true, true, true, false, true,
];

/// Penalty contribution of one row or column: N1 (runs) and N3 (finder-like
/// windows).
fn line_penalty(line: &[bool]) -> u32 {
    let mut score = 0;
    let mut run = 1;
    for i in 1..line.len() {
        if line[i] == line[i - 1] {
            run += 1;
        } else {
            if run >= 5 {
                score += 3 + (run - 5);
            }
            run = 1;
        }
    }
    if run >= 5 {
        score += 3 + (run - 5);
    }
    for w in line.windows(11) {
        if w == FINDER_LIKE_A {
            score += 40;
        }
        if w == FINDER_LIKE_B {
            score += 40;
        }
    }
    score
}

/// Total penalty score of the fully drawn symbol `m`.
pub fn penalty(m: &Matrix) -> u32 {
    let n = m.size();
    let mut score = 0;
    let mut line = vec![false; n];

    // N1 and N3 on rows, then columns.
    for y in 0..n {
        for (x, cell) in line.iter_mut().enumerate() {
            *cell = m.get(x, y);
        }
        score += line_penalty(&line);
    }
    for x in 0..n {
        for (y, cell) in line.iter_mut().enumerate() {
            *cell = m.get(x, y);
        }
        score += line_penalty(&line);
    }

    // N2: 2x2 blocks of one colour.
    for y in 0..n - 1 {
        for x in 0..n - 1 {
            let c = m.get(x, y);
            if c == m.get(x + 1, y) && c == m.get(x, y + 1) && c == m.get(x + 1, y + 1) {
                score += 3;
            }
        }
    }

    // N4: deviation of dark proportion from 50%.
    let dark = (0..n)
        .flat_map(|y| (0..n).map(move |x| (x, y)))
        .filter(|&(x, y)| m.get(x, y))
        .count() as i64;
    let total = (n * n) as i64;
    let k = (20 * dark - 10 * total).abs() / total;
    score + 10 * k as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_scoring() {
        // Run of 5 -> 3, run of 7 -> 5.
        assert_eq!(line_penalty(&[true; 5]), 3);
        assert_eq!(line_penalty(&[false; 7]), 5);
        assert_eq!(line_penalty(&[true, false, true, false, true, false]), 0);
    }

    #[test]
    fn finder_like_scoring() {
        let mut v = vec![false; 4];
        v.extend([true, false, true, true, true, false, true]);
        v.extend([false; 4]);
        // "....#.###.#...." contains both patterns.
        assert_eq!(line_penalty(&v), 80);
    }
}
