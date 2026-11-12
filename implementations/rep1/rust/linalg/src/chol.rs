//! Cholesky factorisation.

use crate::error::{LinalgError, Result};
use crate::matrix::Matrix;

/// Lower triangular `L` with `A = L Lᵀ` for symmetric positive definite `A`.
///
/// Fails with `NotSquare`, `NotSymmetric` or `NotPositiveDefinite`.
pub fn cholesky(a: &Matrix) -> Result<Matrix> {
    a.require_symmetric()?;
    let n = a.rows();
    let mut l = Matrix::zeros(n, n);
    for j in 0..n {
        let mut s = a.get(j, j);
        for k in 0..j {
            let v = l.get(j, k);
            s -= v * v;
        }
        if s <= 0.0 {
            return Err(LinalgError::NotPositiveDefinite);
        }
        let d = s.sqrt();
        l.set(j, j, d);
        for i in j + 1..n {
            let mut t = a.get(i, j);
            for k in 0..j {
                t -= l.get(i, k) * l.get(j, k);
            }
            l.set(i, j, t / d);
        }
    }
    Ok(l)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_by_two() {
        let a = Matrix::from_rows(&[vec![4.0, 2.0], vec![2.0, 5.0]]);
        let l = cholesky(&a).unwrap();
        assert_eq!(l, Matrix::from_rows(&[vec![2.0, 0.0], vec![1.0, 2.0]]));
    }

    #[test]
    fn errors() {
        assert_eq!(cholesky(&Matrix::zeros(2, 3)).unwrap_err(), LinalgError::NotSquare);
        let ns = Matrix::from_rows(&[vec![1.0, 2.0], vec![0.0, 1.0]]);
        assert_eq!(cholesky(&ns).unwrap_err(), LinalgError::NotSymmetric);
        let indef = Matrix::from_rows(&[vec![1.0, 2.0], vec![2.0, 1.0]]);
        assert_eq!(cholesky(&indef).unwrap_err(), LinalgError::NotPositiveDefinite);
    }
}
