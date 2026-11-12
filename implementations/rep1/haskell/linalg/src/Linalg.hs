-- | Dense real linear algebra over 'Double'.
--
-- This module re-exports the whole public API:
--
-- * "Linalg.Matrix": the dense 'Linalg.Matrix.Matrix' type, arithmetic, norms;
-- * "Linalg.LU": LU with partial pivoting, determinant, solve, inverse;
-- * "Linalg.QR": Householder QR and least squares;
-- * "Linalg.Cholesky": Cholesky factorisation;
-- * "Linalg.Eigen": cyclic Jacobi symmetric eigendecomposition;
-- * "Linalg.SVD": one-sided Jacobi SVD and condition number;
-- * "Linalg.MatrixMarket": Matrix Market reading and writing;
-- * "Linalg.Operation" and "Linalg.Runner": the scripting layer used by the
--   command line tool.
--
-- Matrix names that clash with "Prelude" or between modules (@add@, @(!)@,
-- ...) are best imported qualified:
--
-- > import qualified Linalg.Matrix as M
-- > import Linalg
module Linalg
  ( module Linalg.Matrix
  , module Linalg.Error
  , module Linalg.LU
  , module Linalg.QR
  , module Linalg.Cholesky
  , module Linalg.Eigen
  , module Linalg.SVD
  , module Linalg.MatrixMarket
  , module Linalg.Operation
  , module Linalg.Runner
  ) where

import Linalg.Cholesky
import Linalg.Eigen
import Linalg.Error
import Linalg.LU
import Linalg.Matrix
import Linalg.MatrixMarket
import Linalg.Operation
import Linalg.QR
import Linalg.Runner
import Linalg.SVD
