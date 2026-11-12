//! The sign convention for eigenvectors and singular vectors.

/// Negate `col` if its largest-magnitude entry (smallest index on ties) is
/// negative. Returns `true` when the column was negated. An all-zero column
/// is left unchanged.
pub fn normalize_column_sign(col: &mut [f64]) -> bool {
    let mut best = 0.0;
    let mut sign_negative = false;
    for &x in col.iter() {
        if x.abs() > best {
            best = x.abs();
            sign_negative = x < 0.0;
        }
    }
    if sign_negative {
        for x in col.iter_mut() {
            *x = -*x;
        }
    }
    sign_negative
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flips_when_largest_is_negative() {
        let mut v = [0.5, -2.0, 1.0];
        assert!(normalize_column_sign(&mut v));
        assert_eq!(v, [-0.5, 2.0, -1.0]);
    }

    #[test]
    fn keeps_when_positive_and_first_on_ties() {
        let mut v = [1.0, -1.0];
        assert!(!normalize_column_sign(&mut v));
        assert_eq!(v, [1.0, -1.0]);
        let mut z = [0.0, 0.0];
        assert!(!normalize_column_sign(&mut z));
    }
}
