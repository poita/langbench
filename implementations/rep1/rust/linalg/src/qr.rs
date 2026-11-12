//! Householder QR factorisation and least squares.

use crate::error::{LinalgError, Result};
use crate::matrix::Matrix;

/// Thin QR factorisation `A = Q R`.
#[derive(Debug, Clone)]
pub struct Qr {
    /// `m x n` with orthonormal columns.
    pub q: Matrix,
    /// `n x n` upper triangular with a non-negative diagonal.
    pub r: Matrix,
}

/// Compute the thin Householder QR of an `m x n` matrix with `m >= n`.
///
/// The factorisation is made unique by forcing the diagonal of `R` to be
/// non-negative. Rank-deficient input is accepted.
pub fn qr(a: &Matrix) -> Result<Qr> {
    let (m, n) = (a.rows(), a.cols());
    if m < n {
        return Err(LinalgError::DimensionMismatch);
    }
    let mut r = a.clone();
    // Stored reflectors: reflectors[k] is the unit vector v for column k
    // (length m - k), or None for an identity reflector.
    let mut reflectors: Vec<Option<Vec<f64>>> = Vec::with_capacity(n);
    for k in 0..n {
        let mut sumsq = 0.0;
        for i in k..m {
            let x = r.get(i, k);
            sumsq += x * x;
        }
        let nu = sumsq.sqrt();
        if nu == 0.0 {
            for i in k + 1..m {
                r.set(i, k, 0.0);
            }
            reflectors.push(None);
            continue;
        }
        let alpha = if r.get(k, k) >= 0.0 { -nu } else { nu };
        let mut v: Vec<f64> = (k..m).map(|i| r.get(i, k)).collect();
        v[0] -= alpha;
        let mut vn = 0.0;
        for x in &v {
            vn += x * x;
        }
        let vn = vn.sqrt();
        for x in v.iter_mut() {
            *x /= vn;
        }
        // Apply the reflector to the remaining columns, row-wise so that
        // memory access stays contiguous; each dot product still runs over
        // increasing row index.
        let width = n - k - 1;
        if width > 0 {
            let mut dots = vec![0.0; width];
            for (idx, &vi) in v.iter().enumerate() {
                let row = &r.row(k + idx)[k + 1..];
                for (d, x) in dots.iter_mut().zip(row) {
                    *d += vi * x;
                }
            }
            for (idx, &vi) in v.iter().enumerate() {
                let row = &mut r.row_mut(k + idx)[k + 1..];
                for (x, d) in row.iter_mut().zip(&dots) {
                    *x -= 2.0 * d * vi;
                }
            }
        }
        r.set(k, k, alpha);
        for i in k + 1..m {
            r.set(i, k, 0.0);
        }
        reflectors.push(Some(v));
    }

    // Q = H_0 H_1 ... H_{n-1} applied to the first n columns of the identity.
    let mut q = Matrix::zeros(m, n);
    for j in 0..n {
        q.set(j, j, 1.0);
    }
    for k in (0..n).rev() {
        if let Some(v) = &reflectors[k] {
            let mut dots = vec![0.0; n];
            for (idx, &vi) in v.iter().enumerate() {
                for (d, x) in dots.iter_mut().zip(q.row(k + idx)) {
                    *d += vi * x;
                }
            }
            for (idx, &vi) in v.iter().enumerate() {
                for (x, d) in q.row_mut(k + idx).iter_mut().zip(&dots) {
                    *x -= 2.0 * d * vi;
                }
            }
        }
    }

    // Normalise: non-negative diagonal on R, exact zeros below it.
    let mut r_out = Matrix::zeros(n, n);
    for i in 0..n {
        for j in i..n {
            r_out.set(i, j, r.get(i, j));
        }
    }
    for j in 0..n {
        if r_out.get(j, j) < 0.0 {
            for c in j..n {
                let v = r_out.get(j, c);
                r_out.set(j, c, -v);
            }
            for i in 0..m {
                let v = q.get(i, j);
                q.set(i, j, -v);
            }
        }
    }
    Ok(Qr { q, r: r_out })
}

/// Least-squares solution of `A X = B` for full-column-rank `A` (`m >= n`).
///
/// Fails with `DimensionMismatch` if `m < n` or `B` has the wrong number of
/// rows, and with `Singular` if `R` has an exactly zero diagonal entry.
pub fn lstsq(a: &Matrix, b: &Matrix) -> Result<Matrix> {
    if a.rows() < a.cols() || b.rows() != a.rows() {
        return Err(LinalgError::DimensionMismatch);
    }
    let Qr { q, r } = qr(a)?;
    let (m, n, k) = (a.rows(), a.cols(), b.cols());
    if (0..n).any(|i| r.get(i, i) == 0.0) {
        return Err(LinalgError::Singular);
    }
    // Qᵀ B, each entry summed over increasing row index.
    let mut qtb = Matrix::zeros(n, k);
    for i in 0..m {
        for j in 0..n {
            let qij = q.get(i, j);
            let out = qtb.row_mut(j);
            for (o, bv) in out.iter_mut().zip(b.row(i)) {
                *o += qij * bv;
            }
        }
    }
    let mut x = Matrix::zeros(n, k);
    for c in 0..k {
        for i in (0..n).rev() {
            let mut s = qtb.get(i, c);
            for j in i + 1..n {
                s -= r.get(i, j) * x.get(j, c);
            }
            x.set(i, c, s / r.get(i, i));
        }
    }
    Ok(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(rows: &[&[f64]]) -> Matrix {
        Matrix::from_rows(&rows.iter().map(|r| r.to_vec()).collect::<Vec<_>>())
    }

    fn close(a: &Matrix, b: &Matrix, tol: f64) -> bool {
        a.rows() == b.rows()
            && a.cols() == b.cols()
            && a.as_slice().iter().zip(b.as_slice()).all(|(x, y)| (x - y).abs() <= tol)
    }

    #[test]
    fn single_column_sign_normalised() {
        let f = qr(&m(&[&[3.0], &[4.0]])).unwrap();
        assert!((f.r.get(0, 0) - 5.0).abs() < 1e-14);
        assert!((f.q.get(0, 0) - 0.6).abs() < 1e-14);
        assert!((f.q.get(1, 0) - 0.8).abs() < 1e-14);
    }

    #[test]
    fn reconstructs_and_is_orthonormal() {
        let a = m(&[&[1.0, 2.0], &[3.0, 4.0], &[5.0, 7.0], &[-1.0, 0.5]]);
        let f = qr(&a).unwrap();
        assert!(close(&f.q.mul(&f.r).unwrap(), &a, 1e-13));
        let qtq = f.q.transpose().mul(&f.q).unwrap();
        assert!(close(&qtq, &Matrix::identity(2), 1e-14));
        assert_eq!(f.r.get(1, 0), 0.0);
        assert!(f.r.get(0, 0) >= 0.0 && f.r.get(1, 1) >= 0.0);
    }

    #[test]
    fn rank_deficient_qr_succeeds_but_lstsq_fails() {
        let a = m(&[&[1.0, 0.0], &[2.0, 0.0], &[3.0, 0.0]]);
        assert!(qr(&a).is_ok());
        let b = m(&[&[1.0], &[2.0], &[3.0]]);
        assert_eq!(lstsq(&a, &b).unwrap_err(), LinalgError::Singular);
    }

    #[test]
    fn lstsq_fits_a_line() {
        let a = m(&[&[1.0, 0.0], &[1.0, 1.0], &[1.0, 2.0]]);
        let b = m(&[&[1.0], &[3.0], &[5.0]]);
        let x = lstsq(&a, &b).unwrap();
        assert!(close(&x, &m(&[&[1.0], &[2.0]]), 1e-13));
    }

    #[test]
    fn shape_errors() {
        let wide = Matrix::zeros(2, 3);
        assert_eq!(qr(&wide).unwrap_err(), LinalgError::DimensionMismatch);
        let a = Matrix::identity(2);
        let b = Matrix::zeros(3, 1);
        assert_eq!(lstsq(&a, &b).unwrap_err(), LinalgError::DimensionMismatch);
    }
}
