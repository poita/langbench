//! A dense, row-major matrix of `f64` and the elementwise operations,
//! products and norms defined on it.

use crate::error::{LinalgError, Result};

/// A dense `rows x cols` matrix of `f64`, stored row-major.
#[derive(Debug, Clone, PartialEq)]
pub struct Matrix {
    rows: usize,
    cols: usize,
    data: Vec<f64>,
}

impl Matrix {
    /// A matrix of zeros.
    pub fn zeros(rows: usize, cols: usize) -> Matrix {
        Matrix { rows, cols, data: vec![0.0; rows * cols] }
    }

    /// The `n x n` identity matrix.
    pub fn identity(n: usize) -> Matrix {
        let mut m = Matrix::zeros(n, n);
        for i in 0..n {
            m.data[i * n + i] = 1.0;
        }
        m
    }

    /// Build a matrix from row-major data.
    ///
    /// # Panics
    /// Panics if `data.len() != rows * cols`.
    pub fn from_vec(rows: usize, cols: usize, data: Vec<f64>) -> Matrix {
        assert_eq!(data.len(), rows * cols, "data length does not match shape");
        Matrix { rows, cols, data }
    }

    /// Build a matrix from a slice of equally long rows.
    ///
    /// # Panics
    /// Panics if the rows have different lengths.
    pub fn from_rows(rows: &[Vec<f64>]) -> Matrix {
        let r = rows.len();
        let c = rows.first().map_or(0, |row| row.len());
        let mut data = Vec::with_capacity(r * c);
        for row in rows {
            assert_eq!(row.len(), c, "ragged rows");
            data.extend_from_slice(row);
        }
        Matrix { rows: r, cols: c, data }
    }

    /// Number of rows.
    pub fn rows(&self) -> usize {
        self.rows
    }

    /// Number of columns.
    pub fn cols(&self) -> usize {
        self.cols
    }

    /// `true` when the matrix is square.
    pub fn is_square(&self) -> bool {
        self.rows == self.cols
    }

    /// The row-major backing storage.
    pub fn as_slice(&self) -> &[f64] {
        &self.data
    }

    /// Split the storage at the start of row `mid`, returning the rows
    /// before it and the rows from `mid` up to (not including) row `end`.
    pub(crate) fn as_mut_slice_split(&mut self, mid: usize, end: usize) -> (&mut [f64], &mut [f64]) {
        let c = self.cols;
        let (top, bottom) = self.data.split_at_mut(mid * c);
        (top, &mut bottom[..(end - mid) * c])
    }

    /// Row `i` as a slice.
    pub fn row(&self, i: usize) -> &[f64] {
        &self.data[i * self.cols..(i + 1) * self.cols]
    }

    /// Row `i` as a mutable slice.
    pub fn row_mut(&mut self, i: usize) -> &mut [f64] {
        let c = self.cols;
        &mut self.data[i * c..(i + 1) * c]
    }

    /// Entry `(i, j)`.
    #[inline]
    pub fn get(&self, i: usize, j: usize) -> f64 {
        self.data[i * self.cols + j]
    }

    /// Set entry `(i, j)`.
    #[inline]
    pub fn set(&mut self, i: usize, j: usize, v: f64) {
        self.data[i * self.cols + j] = v;
    }

    /// Column `j` copied into a vector.
    pub fn col(&self, j: usize) -> Vec<f64> {
        (0..self.rows).map(|i| self.get(i, j)).collect()
    }

    /// Fail with `NotSquare` unless the matrix is square.
    pub fn require_square(&self) -> Result<()> {
        if self.is_square() {
            Ok(())
        } else {
            Err(LinalgError::NotSquare)
        }
    }

    /// `true` when `A[i][j] == A[j][i]` exactly for all `i, j` (square only).
    pub fn is_symmetric(&self) -> bool {
        if !self.is_square() {
            return false;
        }
        let n = self.rows;
        (0..n).all(|i| (0..i).all(|j| self.get(i, j) == self.get(j, i)))
    }

    /// Fail with `NotSquare` / `NotSymmetric` unless the matrix is symmetric.
    pub fn require_symmetric(&self) -> Result<()> {
        self.require_square()?;
        if self.is_symmetric() {
            Ok(())
        } else {
            Err(LinalgError::NotSymmetric)
        }
    }

    /// Elementwise sum `self + other`.
    pub fn add(&self, other: &Matrix) -> Result<Matrix> {
        if self.rows != other.rows || self.cols != other.cols {
            return Err(LinalgError::DimensionMismatch);
        }
        let data = self.data.iter().zip(&other.data).map(|(a, b)| a + b).collect();
        Ok(Matrix { rows: self.rows, cols: self.cols, data })
    }

    /// Matrix product `self * other`; each entry is one running sum over
    /// increasing inner index.
    pub fn mul(&self, other: &Matrix) -> Result<Matrix> {
        if self.cols != other.rows {
            return Err(LinalgError::DimensionMismatch);
        }
        let (m, k, n) = (self.rows, self.cols, other.cols);
        let mut out = Matrix::zeros(m, n);
        // i-k-j loop order is cache friendly and still accumulates every
        // entry over increasing k.
        for i in 0..m {
            let out_row = &mut out.data[i * n..(i + 1) * n];
            for kk in 0..k {
                let a = self.data[i * k + kk];
                let b_row = &other.data[kk * n..(kk + 1) * n];
                for (o, b) in out_row.iter_mut().zip(b_row) {
                    *o += a * b;
                }
            }
        }
        Ok(out)
    }

    /// The transpose.
    pub fn transpose(&self) -> Matrix {
        let mut out = Matrix::zeros(self.cols, self.rows);
        for i in 0..self.rows {
            for j in 0..self.cols {
                out.data[j * self.rows + i] = self.data[i * self.cols + j];
            }
        }
        out
    }

    /// Maximum absolute column sum (columns summed over increasing row).
    pub fn norm1(&self) -> f64 {
        let mut sums = vec![0.0f64; self.cols];
        for i in 0..self.rows {
            for (s, v) in sums.iter_mut().zip(self.row(i)) {
                *s += v.abs();
            }
        }
        sums.into_iter().fold(0.0, f64::max)
    }

    /// Maximum absolute row sum.
    pub fn norm_inf(&self) -> f64 {
        (0..self.rows)
            .map(|i| self.row(i).iter().fold(0.0, |s, v| s + v.abs()))
            .fold(0.0, f64::max)
    }

    /// Frobenius norm; squares are summed row by row, each row left to right.
    pub fn norm_fro(&self) -> f64 {
        let mut total = 0.0;
        for i in 0..self.rows {
            let mut row_sum = 0.0;
            for v in self.row(i) {
                row_sum += v * v;
            }
            total += row_sum;
        }
        f64::sqrt(total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(rows: &[&[f64]]) -> Matrix {
        Matrix::from_rows(&rows.iter().map(|r| r.to_vec()).collect::<Vec<_>>())
    }

    #[test]
    fn add_and_shape_check() {
        let a = m(&[&[1.0, 2.0], &[3.0, 4.0]]);
        let b = m(&[&[0.5, 0.0], &[0.0, -1.5]]);
        assert_eq!(a.add(&b).unwrap(), m(&[&[1.5, 2.0], &[3.0, 2.5]]));
        let c = Matrix::zeros(2, 3);
        assert_eq!(a.add(&c), Err(LinalgError::DimensionMismatch));
    }

    #[test]
    fn mul_rectangular() {
        let a = m(&[&[1.0, 2.0, 3.0]]);
        let b = m(&[&[1.0], &[1.0], &[2.0]]);
        assert_eq!(a.mul(&b).unwrap(), m(&[&[9.0]]));
        assert_eq!(b.mul(&b), Err(LinalgError::DimensionMismatch));
    }

    #[test]
    fn transpose_roundtrip() {
        let a = m(&[&[1.0, 2.0, 3.0], &[4.0, 5.0, 6.0]]);
        let t = a.transpose();
        assert_eq!((t.rows(), t.cols()), (3, 2));
        assert_eq!(t.get(2, 1), 6.0);
        assert_eq!(t.transpose(), a);
    }

    #[test]
    fn norms() {
        let a = m(&[&[1.0, -2.0], &[-3.0, 4.0]]);
        assert_eq!(a.norm1(), 6.0);
        assert_eq!(a.norm_inf(), 7.0);
        assert!((a.norm_fro() - 30f64.sqrt()).abs() < 1e-15);
    }

    #[test]
    fn symmetry() {
        assert!(m(&[&[1.0, 2.0], &[2.0, 1.0]]).is_symmetric());
        assert!(!m(&[&[1.0, 2.0], &[2.5, 1.0]]).is_symmetric());
        assert_eq!(Matrix::zeros(2, 3).require_symmetric(), Err(LinalgError::NotSquare));
    }
}
