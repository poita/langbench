{-# LANGUAGE OverloadedStrings #-}
-- | Model-based tests: the incremental engine must agree, after every edit,
-- with a naive whole-sheet oracle that finds cyclic cells by transitive
-- closure and evaluates everything else through a lazy table.
module Spreadsheet.PropertySpec (spec) where

import qualified Data.IntMap.Lazy as IntMap
import qualified Data.IntSet as IntSet
import Data.List (intercalate)
import Data.Maybe (fromJust)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Spreadsheet
import Spreadsheet.Eval (dependencies, evaluate)
import qualified Spreadsheet.Sheet as Sheet

-- | An edit on a small grid: set a cell to some source text, or clear it.
data Edit = Set Text Text | Clear Text
  deriving (Show)

names :: [Text]
names = [T.pack (c : show r) | r <- [1 .. 3 :: Int], c <- "ABC"]

genName :: Gen Text
genName = elements names

genExprSrc :: Int -> Gen String
genExprSrc 0 =
  oneof
    [ show <$> (choose (0, 20) :: Gen Int)
    , (\a b -> show a ++ "." ++ show b) <$> (choose (0, 9) :: Gen Int) <*> (choose (1, 9) :: Gen Int)
    , elements ["\"\"", "\"a\"", "\"b c\"", "\"10\""]
    , T.unpack <$> genName
    , T.unpack <$> genName
    ]
genExprSrc d = frequency
  [ (2, genExprSrc 0)
  , (4, do op <- elements ["+", "-", "*", "/", "&", "=", "<>", "<", ">", "<=", ">="]
           a <- genExprSrc (d - 1)
           b <- genExprSrc (d - 1)
           pure ("(" ++ a ++ op ++ b ++ ")"))
  , (1, ("-" ++) <$> genExprSrc (d - 1))
  , (2, do c <- genExprSrc (d - 1); a <- genExprSrc (d - 1); b <- genExprSrc (d - 1)
           pure ("IF(" ++ c ++ "," ++ a ++ "," ++ b ++ ")"))
  , (3, do f <- elements ["SUM", "MIN", "MAX", "AVG", "COUNT"]
           args <- listOf1 (resize 2 (oneof [Left <$> genExprSrc (d - 1), Right <$> ((,) <$> genName <*> genName)]))
           pure (f ++ "(" ++ intercalate "," (map arg args) ++ ")"))
  ]
  where
    arg (Left s) = s
    arg (Right (a, b)) = T.unpack a ++ ":" ++ T.unpack b

genContent :: Gen Text
genContent =
  frequency
    [ (2, T.pack . show <$> (choose (-5, 50) :: Gen Int))
    , (1, elements ["\"x\"", "\"\"", "\"7\""])
    , (6, T.pack . ('=' :) <$> sized (\n -> genExprSrc (min 3 (n `div` 10 + 1))))
    ]

genEdit :: Gen Edit
genEdit = frequency [(6, Set <$> genName <*> genContent), (1, Clear <$> genName)]

cell :: Text -> CellRef
cell = fromJust . parseCellRef

apply :: Edit -> Sheet -> Sheet
apply (Set n t) s = either (error . show) id (setCell (cell n) t s)
apply (Clear n) s = clearCell (cell n) s

-- | The oracle: the contents after the edits, evaluated from scratch.
oracle :: [Edit] -> [(CellRef, Value)]
oracle edits = [(keyRef k, v) | (k, v) <- IntMap.toAscList values]
  where
    contents = foldl step IntMap.empty edits
    step m (Set n t) = IntMap.insert (refKey (cell n)) (either (error . show) id (parseContent t)) m
    step m (Clear n) = IntMap.delete (refKey (cell n)) m
    deps = IntMap.map (\c -> case c of CFormula e -> dependencies e; _ -> IntSet.empty) contents
    -- Cyclic: reachable from itself.
    reachable k = go IntSet.empty (IntSet.toList (IntMap.findWithDefault IntSet.empty k deps))
      where
        go seen [] = seen
        go seen (x : xs)
          | IntSet.member x seen = go seen xs
          | otherwise = go (IntSet.insert x seen) (IntSet.toList (IntMap.findWithDefault IntSet.empty x deps) ++ xs)
    cyclic = IntSet.fromList [k | k <- IntMap.keys contents, IntSet.member k (reachable k)]
    values = IntMap.mapWithKey value contents
    value k c
      | IntSet.member k cyclic = VError ErrCycle
      | otherwise = case c of
          CNumber d -> VNumber d
          CText t -> VText t
          CFormula e -> evaluate (`IntMap.lookup` values) e

spec :: Spec
spec = do
  prop "agrees with a from-scratch oracle after every edit" $
    forAll (resize 40 (listOf genEdit)) $ \edits ->
      conjoin
        [ Sheet.toList (foldr apply Sheet.empty (reverse prefix)) === oracle prefix
        | n <- [1 .. length edits]
        , let prefix = take n edits
        ]
  prop "the final state does not depend on the order cells were set" $
    forAll (resize 30 (listOf1 genEdit)) $ \edits ->
      let sheet = foldl (flip apply) Sheet.empty edits
          -- Re-set every non-empty cell from its stored content, in reverse order.
          again =
            foldl
              (\s (ref, c) -> setContent ref c s)
              Sheet.empty
              (reverse [(r, fromJust (lookupContent r sheet)) | (r, _) <- Sheet.toList sheet])
       in Sheet.toList again === Sheet.toList sheet
  prop "get is consistent with dump" $
    forAll (resize 30 (listOf genEdit)) $ \edits ->
      let sheet = foldl (flip apply) Sheet.empty edits
       in conjoin [lookupValue r sheet === Just v | (r, v) <- Sheet.toList sheet]
