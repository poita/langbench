-- | The sixteen operations of the command language, and their evaluation on
-- already-loaded matrices.
module Linalg.Operation
  ( Operation (..)
  , Result
  , operationName
  , parseOperation
  , arity
  , execute
  ) where

import Linalg.Cholesky (cholesky)
import Linalg.Eigen (Eigen (..), eigSym)
import Linalg.Error (LinalgError (..))
import Linalg.LU (det, inverse, lu, solve)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M
import Linalg.QR (QR (..), lstsq, qr)
import Linalg.SVD (SVD (..), cond, svd)

-- | A command of the script language.
data Operation
  = OpAdd
  | OpMul
  | OpTranspose
  | OpLU
  | OpDet
  | OpInv
  | OpSolve
  | OpQR
  | OpChol
  | OpEig
  | OpSVD
  | OpLstsq
  | OpNorm1
  | OpNormInf
  | OpNormFro
  | OpCond
  deriving (Eq, Show, Enum, Bounded)

-- | The result matrices of an operation, each with its file-name suffix
-- (@"lu_P"@, @"lu_L"@, ...).
type Result = [(String, Matrix)]

-- | The spelling used in scripts.
operationName :: Operation -> String
operationName op = case op of
  OpAdd -> "add"
  OpMul -> "mul"
  OpTranspose -> "transpose"
  OpLU -> "lu"
  OpDet -> "det"
  OpInv -> "inv"
  OpSolve -> "solve"
  OpQR -> "qr"
  OpChol -> "chol"
  OpEig -> "eig"
  OpSVD -> "svd"
  OpLstsq -> "lstsq"
  OpNorm1 -> "norm1"
  OpNormInf -> "norminf"
  OpNormFro -> "normfro"
  OpCond -> "cond"

-- | Look an operation up by its (case-sensitive) script name.
parseOperation :: String -> Maybe Operation
parseOperation name = lookup name [(operationName op, op) | op <- [minBound .. maxBound]]

-- | Number of matrix arguments.
arity :: Operation -> Int
arity op = case op of
  OpAdd -> 2
  OpMul -> 2
  OpSolve -> 2
  OpLstsq -> 2
  _ -> 1

scalar :: Double -> Matrix
scalar x = M.fromList 1 1 [x]

column :: [Double] -> Matrix
column xs = M.fromList (length xs) 1 xs

-- | Run an operation on its arguments. The argument list must have exactly
-- 'arity' elements (otherwise 'error' is called).
execute :: Operation -> [Matrix] -> Either LinalgError Result
execute op args = case (op, args) of
  (OpAdd, [a, b]) -> one "add" <$> M.add a b
  (OpMul, [a, b]) -> one "mul" <$> M.mul a b
  (OpTranspose, [a]) -> Right [("transpose", M.transpose a)]
  (OpLU, [a]) -> (\(p, l, u) -> [("lu_P", p), ("lu_L", l), ("lu_U", u)]) <$> lu a
  (OpDet, [a]) -> one "det" . scalar <$> det a
  (OpInv, [a]) -> one "inv" <$> inverse a
  (OpSolve, [a, b]) -> one "solve" <$> solve a b
  (OpQR, [a]) -> (\(QR q r) -> [("qr_Q", q), ("qr_R", r)]) <$> qr a
  (OpChol, [a]) -> one "chol_L" <$> cholesky a
  (OpEig, [a]) -> (\(Eigen w v) -> [("eig_w", column w), ("eig_V", v)]) <$> eigSym a
  (OpSVD, [a]) ->
    let SVD u s v = svd a in Right [("svd_U", u), ("svd_S", column s), ("svd_V", v)]
  (OpLstsq, [a, b]) -> one "lstsq" <$> lstsq a b
  (OpNorm1, [a]) -> Right [("norm1", scalar (M.norm1 a))]
  (OpNormInf, [a]) -> Right [("norminf", scalar (M.normInf a))]
  (OpNormFro, [a]) -> Right [("normfro", scalar (M.normFrobenius a))]
  (OpCond, [a]) -> one "cond" . scalar <$> cond a
  _ -> error ("Linalg.Operation.execute: wrong number of arguments for " ++ operationName op)
  where
    one name m = [(name, m)]
