-- | Liang hyphenation: pattern files (@.chp@) and the break-point finder.
module Typeset.Hyphenation
  ( Patterns (..)
  , PatternSets (..)
  , parsePatterns
  , loadPatterns
  , patternsFor
  , liangBreaks
  ) where

import Data.Char (isDigit, ord)
import qualified Data.Map.Strict as M
import System.FilePath ((</>), (<.>))

import Typeset.Font (ioReadUtf8, stripComment)
import Typeset.Types (PatternName (..))

-- | A parsed pattern set.
data Patterns = Patterns
  { patLeft    :: !Int
  , patRight   :: !Int
  , patTable   :: M.Map String [Int]   -- ^ key to the @length key + 1@ values
  , patMaxKey  :: !Int
  , patExcepts :: M.Map String [Int]   -- ^ word to break positions
  } deriving (Show)

-- | Both supplied sets.
data PatternSets = PatternSets { setEnglish :: Patterns, setMinimal :: Patterns }

-- | Select the active set.
patternsFor :: PatternSets -> PatternName -> Patterns
patternsFor s English = setEnglish s
patternsFor s Minimal = setMinimal s

-- | Parse the text of a @.chp@ file.
parsePatterns :: String -> Patterns
parsePatterns txt = fin (foldl step (Patterns 0 0 M.empty 0 M.empty) recs)
  where
    recs = filter (not . null) (map (words . stripComment) (lines txt))
    step p ws = case ws of
      ["left", n] -> p { patLeft = read n }
      ["right", n] -> p { patRight = read n }
      ["pattern", s] -> let (k, vs) = decodePattern s
                        in p { patTable = M.insert k vs (patTable p) }
      ["exception", s] -> let (k, ps) = decodeException s
                          in p { patExcepts = M.insert k ps (patExcepts p) }
      _ -> p
    fin p = p { patMaxKey = if M.null (patTable p) then 0 else maximum (map length (M.keys (patTable p))) }

-- | Split a pattern into its key and the values at the @m + 1@ positions.
decodePattern :: String -> (String, [Int])
decodePattern s = (key, vals)
  where
    (key, vals) = go s 0 [] []
    -- go input pendingDigit keyAcc valAcc
    go :: String -> Int -> String -> [Int] -> (String, [Int])
    go [] pend k v = (reverse k, reverse (pend : v))
    go (c : cs) pend k v
      | isDigit c = go cs (ord c - ord '0') k v
      | otherwise = go cs 0 (c : k) (pend : v)

-- | Split an exception into its key and the break positions.
decodeException :: String -> (String, [Int])
decodeException = go 0 [] []
  where
    go _ k ps [] = (reverse k, reverse ps)
    go n k ps (c : cs)
      | c == '-' = go n k (n : ps) cs
      | otherwise = go (n + 1) (c : k) ps cs

-- | Load @english.chp@ and @minimal.chp@ from @\<dataDir\>/hyphen@.
loadPatterns :: FilePath -> IO PatternSets
loadPatterns dir = do
  e <- parsePatterns <$> ioReadUtf8 (dir </> "hyphen" </> "english" <.> "chp")
  m <- parsePatterns <$> ioReadUtf8 (dir </> "hyphen" </> "minimal" <.> "chp")
  return (PatternSets e m)

-- | The permitted break positions of a lowercase all-letter segment: @q@
-- means "after @q@ letters".  Applies Liang's algorithm (or the segment's
-- exception) and the @left@/@right@ minima.
liangBreaks :: Patterns -> String -> [Int]
liangBreaks pats seg = filter ok raw
  where
    n = length seg
    ok q = q >= patLeft pats && q <= n - patRight pats
    raw = case M.lookup seg (patExcepts pats) of
      Just ps -> ps
      Nothing -> [ q | q <- [1 .. n - 1], odd (vAt (1 + q)) ]
    t = '.' : seg ++ "."
    tl = n + 2
    maxK = patMaxKey pats
    -- value at position p: max over all matching patterns
    vals :: M.Map Int Int
    vals = M.fromListWith max
      [ (i + k, x)
      | i <- [0 .. tl - 1]
      , j <- [i + 1 .. min tl (i + maxK)]
      , Just vs <- [M.lookup (take (j - i) (drop i t)) (patTable pats)]
      , (k, x) <- zip [0 ..] vs
      , x > 0
      ]
    vAt p = M.findWithDefault 0 p vals
