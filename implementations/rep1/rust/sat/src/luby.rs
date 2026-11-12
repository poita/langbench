//! The Luby restart sequence.

/// Returns `y^k` where `k` is the exponent of the `x`-th (0-based) element
/// of the Luby sequence `1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...` scaled by `y`.
///
/// `luby(2.0, i)` is therefore `1, 1, 2, 1, 1, 2, 4, ...`.
pub fn luby(y: f64, mut x: u64) -> f64 {
    let mut size: u64 = 1;
    let mut seq: i32 = 0;
    while size < x + 1 {
        seq += 1;
        size = 2 * size + 1;
    }
    while size - 1 != x {
        size = (size - 1) >> 1;
        seq -= 1;
        x %= size;
    }
    y.powi(seq)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_terms() {
        let got: Vec<u32> = (0..15).map(|i| luby(2.0, i) as u32).collect();
        assert_eq!(got, vec![1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]);
    }
}
