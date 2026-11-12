//! # linalg
//!
//! A small dense real linear algebra library written from scratch (no BLAS,
//! LAPACK or other numerical dependencies), together with the Matrix Market
//! I/O and script driver used by the `linalg` command-line tool.
//!
//! Modules:
//!
//! * [`matrix`] – the dense [`Matrix`] type, elementwise ops, products, norms
//! * [`lu`] – LU with partial pivoting, determinant, solve, inverse
//! * [`qr`] – Householder QR and least squares
//! * [`chol`] – Cholesky factorisation
//! * [`eig`] – symmetric eigendecomposition (cyclic Jacobi)
//! * [`svd`] – thin SVD (one-sided Jacobi) and condition number
//! * [`signs`] – the sign convention for eigen/singular vectors
//! * [`mmio`] – Matrix Market reader and writer
//! * [`script`] – parsing and running command scripts
//! * [`error`] – the shared [`LinalgError`]
//!
//! Every sum is a single running sum in the natural index order, so results
//! are deterministic and reproducible.
//!
//! ```
//! use linalg::{Matrix, lu};
//!
//! let a = Matrix::from_rows(&[vec![1.0, 2.0], vec![3.0, 4.0]]);
//! let b = Matrix::from_rows(&[vec![5.0], vec![6.0]]);
//! let x = lu::solve(&a, &b).unwrap();
//! assert!((x.get(0, 0) + 4.0).abs() < 1e-12);
//! assert!((x.get(1, 0) - 4.5).abs() < 1e-12);
//! ```

pub mod chol;
pub mod eig;
pub mod error;
pub mod lu;
pub mod matrix;
pub mod mmio;
pub mod qr;
pub mod script;
pub mod signs;
pub mod svd;

pub use error::{LinalgError, Result};
pub use matrix::Matrix;
