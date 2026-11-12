-- | The ways a linear algebra operation can fail.
module Linalg.Error
  ( LinalgError (..)
  , errorCode
  ) where

-- | Reasons an operation cannot be carried out.
data LinalgError
  = DimensionMismatch
    -- ^ The operand shapes are incompatible (e.g. adding a 2x2 and a 3x3).
  | NotSquare
    -- ^ A square matrix was required.
  | NotSymmetric
    -- ^ A symmetric matrix was required (compared as exact doubles).
  | NotPositiveDefinite
    -- ^ Cholesky met a non-positive pivot.
  | Singular
    -- ^ A pivot was exactly zero (or the smallest singular value was).
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | The stable, snake_case identifier of an error, as written by the
-- command line tool.
errorCode :: LinalgError -> String
errorCode DimensionMismatch = "dimension_mismatch"
errorCode NotSquare = "not_square"
errorCode NotSymmetric = "not_symmetric"
errorCode NotPositiveDefinite = "not_positive_definite"
errorCode Singular = "singular"
