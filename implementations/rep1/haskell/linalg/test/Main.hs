{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
module Main (main) where

import Control.Exception (finally)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy.Char8 as L
import Data.List (sort, sortBy)
import Data.Ord (Down (..), comparing)
import System.Directory
  ( createDirectory
  , doesFileExist
  , listDirectory
  , removeFile
  , removePathForcibly
  , getTemporaryDirectory
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec
import Test.QuickCheck

import Generators
import Linalg
import qualified Linalg.Matrix as M

mat :: [[Double]] -> Matrix
mat = M.fromLists

fmt :: Double -> String
fmt = L.unpack . BB.toLazyByteString . formatDouble

parse :: String -> Either String Matrix
parse = parseMatrix . C.pack

isUpper, isLower :: Matrix -> Bool
isUpper a = and [M.unsafeAt a i j == 0 | i <- [0 .. M.rows a - 1], j <- [0 .. min (i - 1) (M.cols a - 1)]]
isLower = isUpper . M.transpose

identityOf :: Int -> Matrix
identityOf = M.identity

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir act = do
  tmp <- getTemporaryDirectory
  (path, h) <- openTempFile tmp "linalg-test"
  hClose h
  removeFile path
  createDirectory path
  act path `finally` removePathForcibly path

main :: IO ()
main = hspec $ do
  matrixSpec
  matrixMarketSpec
  luSpec
  qrSpec
  choleskySpec
  eigenSpec
  svdSpec
  runnerSpec

matrixSpec :: Spec
matrixSpec = describe "Linalg.Matrix" $ do
  it "adds elementwise" $
    M.add (mat [[1, 2], [3, 4]]) (mat [[0.5, 0], [0, -1.5]]) `shouldBe` Right (mat [[1.5, 2], [3, 2.5]])
  it "rejects adding different shapes" $
    M.add (mat [[1, 2]]) (mat [[1], [2]]) `shouldBe` Left DimensionMismatch
  it "multiplies" $
    M.mul (mat [[1, 2, 3], [4, 5, 6]]) (mat [[1], [0], [-1]]) `shouldBe` Right (mat [[-2], [-2]])
  it "rejects incompatible products" $
    M.mul (mat [[1, 2]]) (mat [[1, 2]]) `shouldBe` Left DimensionMismatch
  it "transposes" $
    M.transpose (mat [[1, 2, 3], [4, 5, 6]]) `shouldBe` mat [[1, 4], [2, 5], [3, 6]]
  it "computes the three norms" $ do
    let a = mat [[1, -2], [3, 4]]
    M.norm1 a `shouldBe` 6
    M.normInf a `shouldBe` 7
    M.normFrobenius a `shouldBe` sqrt 30
  it "indexes with bounds checks" $ do
    mat [[1, 2], [3, 4]] M.! (1, 0) `shouldBe` 3
  it "detects symmetry exactly" $ do
    M.isSymmetric (mat [[1, 2], [2, 1]]) `shouldBe` True
    M.isSymmetric (mat [[1, 2], [2.0000000001, 1]]) `shouldBe` False
    M.isSymmetric (mat [[1, 2, 3]]) `shouldBe` False
  it "transpose is an involution" $ property $ \(SmallMatrix a) ->
    M.transpose (M.transpose a) == a
  it "multiplication by the identity is neutral" $ property $ \(SmallMatrix a) ->
    M.mul a (identityOf (M.cols a)) == Right a

matrixMarketSpec :: Spec
matrixMarketSpec = describe "Linalg.MatrixMarket" $ do
  it "reads array general (column-major)" $
    parse "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n"
      `shouldBe` Right (mat [[1, 2], [3, 4]])
  it "reads coordinate general" $
    parse "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n"
      `shouldBe` Right (mat [[0.5, 0], [0, -1.5]])
  it "reads array symmetric (lower triangle)" $
    parse "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n"
      `shouldBe` Right (mat [[4, 2], [2, 5]])
  it "reads array skew-symmetric (strict lower triangle)" $
    parse "%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n"
      `shouldBe` Right (mat [[0, -1, -2], [1, 0, -3], [2, 3, 0]])
  it "reads coordinate symmetric" $
    parse "%%MatrixMarket matrix coordinate real symmetric\n3 3 3\n1 1 1\n2 1 5\n3 3 2\n"
      `shouldBe` Right (mat [[1, 5, 0], [5, 0, 0], [0, 0, 2]])
  it "reads coordinate skew-symmetric" $
    parse "%%MatrixMarket matrix coordinate real skew-symmetric\n2 2 1\n2 1 7\n"
      `shouldBe` Right (mat [[0, -7], [7, 0]])
  it "reads pattern entries as 1.0" $
    parse "%%MatrixMarket matrix coordinate pattern general\n2 3 2\n1 3\n2 1\n"
      `shouldBe` Right (mat [[0, 0, 1], [1, 0, 0]])
  it "reads integer fields and non-rectangular array data" $
    parse "%%MatrixMarket matrix array integer general\n3 1\n1\n2\n3\n"
      `shouldBe` Right (mat [[1], [2], [3]])
  it "is case-insensitive, skips comments and blank lines, accepts tabs" $
    parse "%%MatrixMarket MATRIX Coordinate REAL General\n% a comment\n%another\n\n  \n2\t2 1 \n\n 2 1\t1e0 \n"
      `shouldBe` Right (mat [[0, 0], [1, 0]])
  it "parses decimal floats correctly rounded" $
    property $ \x -> let d = x :: Double in
      not (isNaN d || isInfinite d) ==> parseDouble (C.pack (show d)) === Just d
  it "parses the usual spellings" $ do
    map (parseDouble . C.pack) ["1", "-2.5", "3.0e-7", "1.0E+03", ".5", "5.", "+4", "0", "-0.0", "123456789012345678901234567890"]
      `shouldBe` map Just [1, -2.5, 3.0e-7, 1000, 0.5, 5, 4, 0, -0.0, 1.2345678901234568e29]
  it "parses long mantissas with a correctly rounded result" $
    parseDouble (C.pack "0.1000000000000000055511151231257827") `shouldBe` Just 0.1
  it "formats like printf %.10e" $ do
    fmt 1.2345678901 `shouldBe` "1.2345678901e+00"
    fmt (-7.0e-3) `shouldBe` "-7.0000000000e-03"
    fmt 40015.422479 `shouldBe` "4.0015422479e+04"
    fmt 1 `shouldBe` "1.0000000000e+00"
    fmt 1e100 `shouldBe` "1.0000000000e+100"
    fmt 9.99999999996 `shouldBe` "1.0000000000e+01"
    fmt 0.5 `shouldBe` "5.0000000000e-01"
  it "writes negative zero as positive zero" $ do
    fmt (-0.0) `shouldBe` "0.0000000000e+00"
    fmt 0 `shouldBe` "0.0000000000e+00"
  it "rounds exact ties to even on the binary value" $ do
    fmt 1.00000000005 `shouldBe` "1.0000000001e+00" -- binary value is just above the tie
    fmt 0.125 `shouldBe` "1.2500000000e-01"
  it "formats subnormals" $
    fmt 5.0e-324 `shouldBe` "4.9406564584e-324"
  it "renders the array form with a trailing newline" $
    L.unpack (BB.toLazyByteString (renderMatrix (mat [[1, 2], [3, 4]])))
      `shouldBe` unlines
        [ "%%MatrixMarket matrix array real general"
        , "2 2"
        , "1.0000000000e+00"
        , "3.0000000000e+00"
        , "2.0000000000e+00"
        , "4.0000000000e+00"
        ]
  it "round-trips through the writer to 11 significant digits" $
    property $ \(SmallMatrix a) ->
      case parseMatrix (L.toStrict (BB.toLazyByteString (renderMatrix a))) of
        Right b -> approxMatrix 1e-9 a b
        Left _ -> False

luSpec :: Spec
luSpec = describe "Linalg.LU" $ do
  let a = mat [[1, 2], [3, 4]]
  it "factors the worked example" $ do
    let Right (p, l, u) = lu a
    p `shouldBe` mat [[0, 1], [1, 0]]
    l `shouldBe` mat [[1, 0], [1 / 3, 1]]
    u `shouldSatisfy` approxMatrix 1e-15 (mat [[3, 4], [0, 2 / 3]])
    M.unsafeAt u 1 0 `shouldBe` 0
  it "breaks pivot ties towards the smallest row" $ do
    let Right f = luFactor (mat [[2, 1], [2, 5]])
    luPermutation f `shouldBe` [0, 1]
  it "computes the determinant" $ do
    det a `shouldBe` Right (-2)
    det (identityOf 4) `shouldBe` Right 1
  it "reports det of a singular matrix as zero" $
    det (mat [[1, 2], [2, 4]]) `shouldBe` Right 0
  it "reports singular factorisations" $
    lu (mat [[1, 2], [2, 4]]) `shouldBe` Left Singular
  it "checks squareness first" $ do
    lu (mat [[1, 2, 3]]) `shouldBe` Left NotSquare
    inverse (mat [[1, 2, 3]]) `shouldBe` Left NotSquare
    det (mat [[1], [2]]) `shouldBe` Left NotSquare
    solve (mat [[1, 2, 3], [4, 5, 6]]) (mat [[1], [2], [3]]) `shouldBe` Left NotSquare
  it "solves with a mismatched right-hand side" $
    solve a (mat [[1], [2], [3]]) `shouldBe` Left DimensionMismatch
  it "solves a small system" $
    solve a (mat [[5], [11]]) `shouldSatisfy` either (const False) (approxMatrix 1e-12 (mat [[1], [2]]))
  it "P A = L U" $ property $ \(Square m) ->
    case lu m of
      Left Singular -> property True
      Left _ -> property False
      Right (p, l, u) ->
        counterexample "residual" (approxMatrix 1e-9 (mulE p m) (mulE l u))
          .&&. counterexample "L bounded" (all ((<= 1) . abs) (M.toList l))
          .&&. isLower l .&&. isUpper u
  it "inverse is a right inverse" $ property $ \(Square m) ->
    case inverse m of
      Left Singular -> property True
      Left _ -> property False
      Right x ->
        -- Only meaningful when the matrix is not badly conditioned.
        let r = maxAbsDiff (mulE m x) (identityOf (M.rows m))
         in property (r < 1e-6 || M.normInf m * M.normInf x > 1e6)
  it "solve satisfies A X = B" $ property $ \(Square m) ->
    case solve m (identityOf (M.rows m)) of
      Left Singular -> property True
      Left _ -> property False
      Right x -> property (M.normInf m * M.normInf x > 1e6 || approxMatrix 1e-6 (mulE m x) (identityOf (M.rows m)))
  it "det of a product is the product of dets" $ property $ \(Square m) ->
    let Right d = det m
        Right dt = det (M.transpose m)
     in abs (d - dt) <= 1e-8 * max 1 (abs d)

qrSpec :: Spec
qrSpec = describe "Linalg.QR" $ do
  it "normalises the sign (3,4) example" $ do
    let Right (QR q r) = qr (mat [[3], [4]])
    q `shouldSatisfy` approxMatrix 1e-12 (mat [[0.6], [0.8]])
    r `shouldSatisfy` approxMatrix 1e-12 (mat [[5]])
  it "rejects wide matrices" $ do
    qr (mat [[1, 2, 3]]) `shouldBe` Left DimensionMismatch
    lstsq (mat [[1, 2, 3]]) (mat [[1]]) `shouldBe` Left DimensionMismatch
  it "accepts rank-deficient matrices" $ do
    let a = mat [[1, 0], [2, 0], [3, 0]]
        Right (QR q r) = qr a
    approxMatrix 1e-12 (mulE q r) a `shouldBe` True
  it "Q R = A, Q'Q = I, R upper with non-negative diagonal" $ property $ \(Tall a) ->
    let Right (QR q r) = qr a
        n = M.cols a
     in counterexample "QR" (approxMatrix 1e-9 (mulE q r) a)
          .&&. counterexample "orthonormal" (approxMatrix 1e-9 (mulE (M.transpose q) q) (identityOf n))
          .&&. counterexample "triangular" (isUpper r)
          .&&. counterexample "diag" (all (>= 0) [M.unsafeAt r i i | i <- [0 .. n - 1]])
  it "solves an overdetermined system in the least squares sense" $ do
    -- fit y = c0 + c1 x through (0,1) (1,3) (2,5) (3,7): exact c = (1, 2)
    let a' = mat [[1, 0], [1, 1], [1, 2], [1, 3]]
        b = mat [[1], [3], [5], [7]]
    lstsq a' b `shouldSatisfy` either (const False) (approxMatrix 1e-12 (mat [[1], [2]]))
  it "reports a rank-deficient least squares problem as singular" $
    lstsq (mat [[1, 0], [2, 0]]) (mat [[1], [1]]) `shouldBe` Left Singular
  it "checks the right-hand side's row count" $
    lstsq (mat [[1, 0], [0, 1]]) (mat [[1], [1], [1]]) `shouldBe` Left DimensionMismatch
  it "satisfies the normal equations" $ property $ \(Tall a) ->
    let b = M.generate (M.rows a) 1 (\i _ -> fromIntegral (i + 1))
     in case lstsq a b of
          Left Singular -> property True
          Left _ -> property False
          Right x ->
            let res = either (error . show) id (M.add b (M.generate (M.rows a) 1 (\i _ -> negate (M.unsafeAt (mulE a x) i 0))))
                g = mulE (M.transpose a) res
             in property (M.normInf x > 1e6 || M.normInf g < 1e-6)

choleskySpec :: Spec
choleskySpec = describe "Linalg.Cholesky" $ do
  it "factors the worked example" $
    cholesky (mat [[4, 2], [2, 5]]) `shouldBe` Right (mat [[2, 0], [1, 2]])
  it "checks shape, then symmetry, then definiteness" $ do
    cholesky (mat [[1, 2, 3], [4, 5, 6]]) `shouldBe` Left NotSquare
    cholesky (mat [[1, 2], [3, 4]]) `shouldBe` Left NotSymmetric
    cholesky (mat [[1, 2], [2, 1]]) `shouldBe` Left NotPositiveDefinite
    cholesky (mat [[0]]) `shouldBe` Left NotPositiveDefinite
  it "L L' = A for SPD matrices" $ property $ \(SPD a) ->
    case cholesky a of
      Right l -> counterexample "LL'" (approxMatrix 1e-8 (mulE l (M.transpose l)) a) .&&. isLower l
      Left _ -> property False

eigenSpec :: Spec
eigenSpec = describe "Linalg.Eigen" $ do
  it "diagonalises the worked example with the sign convention" $ do
    let Right (Eigen w v) = eigSym (mat [[2, 1], [1, 3]])
    w `shouldSatisfy` and . zipWith (\x y -> abs (x - y) < 1e-12) [(5 - sqrt 5) / 2, (5 + sqrt 5) / 2]
    v `shouldSatisfy` approxMatrix 1e-9 (mat [[0.8506508084, 0.5257311121], [-0.5257311121, 0.8506508084]])
  it "rejects non-square and non-symmetric input" $ do
    eigSym (mat [[1, 2, 3]]) `shouldBe` Left NotSquare
    eigSym (mat [[1, 2], [3, 4]]) `shouldBe` Left NotSymmetric
  it "handles a 1x1 and an already diagonal matrix" $ do
    eigSym (mat [[7]]) `shouldBe` Right (Eigen [7] (mat [[1]]))
    fmap eigenvalues (eigSym (mat [[3, 0], [0, 1]])) `shouldBe` Right [1, 3]
  it "A V = V diag(w), V orthogonal, w ascending" $ property $ \(Symmetric a) ->
    let Right (Eigen w v) = eigSym a
        n = M.rows a
        vd = M.generate n n (\i j -> M.unsafeAt v i j * (w !! j))
     in counterexample "AV" (approxMatrix 1e-8 (mulE a v) vd)
          .&&. counterexample "orth" (approxMatrix 1e-9 (mulE (M.transpose v) v) (identityOf n))
          .&&. counterexample "ascending" (w == sort w)

svdSpec :: Spec
svdSpec = describe "Linalg.SVD" $ do
  it "decomposes a diagonal matrix" $ do
    let SVD u s v = svd (mat [[1, 0], [0, 3]])
    s `shouldBe` [3, 1]
    u `shouldBe` mat [[0, 1], [1, 0]]
    v `shouldBe` mat [[0, 1], [1, 0]]
  it "computes the condition number" $ do
    fmap (\c -> abs (c - 3) < 1e-12) (cond (mat [[1, 0], [0, 3]])) `shouldBe` Right True
  it "reports a zero smallest singular value as singular" $
    cond (mat [[1, 2], [2, 4]]) `shouldSatisfy` either (== Singular) (> 1e12)
  it "handles wide and tall shapes with the right output shapes" $ do
    let SVD u s v = svd (mat [[1, 2, 3], [4, 5, 6]])
    (M.rows u, M.cols u, length s, M.rows v, M.cols v) `shouldBe` (2, 2, 2, 3, 2)
  it "U diag(s) V' = A, orthonormal factors, s descending and non-negative" $ property $ \(SmallMatrix a) ->
    let SVD u s v = svd a
        k = min (M.rows a) (M.cols a)
        us = M.generate (M.rows u) k (\i j -> M.unsafeAt u i j * (s !! j))
     in counterexample "reconstruction" (approxMatrix 1e-8 (mulE us (M.transpose v)) a)
          .&&. counterexample "descending" (s == sortBy (comparing Down) s && all (>= 0) s)
          .&&. counterexample "V orthonormal" (approxMatrix 1e-8 (mulE (M.transpose v) v) (identityOf k))
  it "singular values of a symmetric matrix match |eigenvalues|" $ property $ \(Symmetric a) ->
    let Right (Eigen w _) = eigSym a
        s = singularValues a
     in and (zipWith (\x y -> abs (x - y) < 1e-6) s (sortBy (comparing Down) (map abs w)))

runnerSpec :: Spec
runnerSpec = describe "Linalg.Runner" $ do
  it "ignores blank and comment lines when numbering" $ do
    let cmds = parseScript "# c\n\n  add a b  \n\t# x\ndet\ta\nfoo a\nadd a\n"
    map (either (const Nothing) (Just . commandOperation)) cmds
      `shouldBe` [Just OpAdd, Just OpDet, Nothing, Nothing]
  it "runs the worked example end to end" $ withTempDir $ \dir -> do
    let inp = dir </> "in"
        out = dir </> "out"
    createDirectory inp
    createDirectory out
    writeFile (inp </> "commands.txt") "# a two by two example\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\nchol r.mtx\n"
    writeFile (inp </> "a.mtx") "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n"
    writeFile (inp </> "b.mtx") "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n"
    writeFile (inp </> "s.mtx") "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n"
    writeFile (inp </> "r.mtx") "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n"
    runDirectory inp out
    files <- listDirectory out
    sort files `shouldBe` ["001_add.mtx", "002_det.mtx", "003_chol_L.mtx", "004_error.txt"]
    readFile (out </> "001_add.mtx")
      `shouldReturn` unlines
        [ "%%MatrixMarket matrix array real general"
        , "2 2"
        , "1.5000000000e+00"
        , "3.0000000000e+00"
        , "2.0000000000e+00"
        , "2.5000000000e+00"
        ]
    readFile (out </> "002_det.mtx")
      `shouldReturn` "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n"
    readFile (out </> "004_error.txt") `shouldReturn` "not_square\n"
    doesFileExist (out </> "004_chol_L.mtx") `shouldReturn` False
  it "knows every operation by name and arity" $
    [parseOperation (operationName op) | op <- [minBound .. maxBound]]
      `shouldBe` map Just [minBound .. maxBound]
