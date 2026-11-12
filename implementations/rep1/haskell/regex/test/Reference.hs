-- | A deliberately naive, purely functional transcription of the matching
-- definition, used as an oracle for the real engine.
module Reference (refSearch) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as M

import qualified Regex.CharSet as CS
import Regex.Syntax

type Caps = M.Map Int (Int, Int)

-- | @m node i caps k@: try each way of matching; @k@ returns the final
-- result or 'Nothing' to ask for the next alternative.  Because captures are
-- an immutable map, abandoned paths are "undone" for free.
type K r = Int -> Caps -> Maybe r

refSearch :: Node -> B.ByteString -> Maybe (Int, Int, Caps)
refSearch tree s = go 0
  where
    len = B.length s
    go st
      | st > len = Nothing
      | otherwise = case m tree st M.empty (\j c -> Just (st, j, c)) of
          Just r  -> Just r
          Nothing -> go (st + 1)

    m :: Node -> Int -> Caps -> K r -> Maybe r
    m node i caps k = case node of
      Lit c    -> one (== c)
      AnyChar  -> one (const True)
      Set cs   -> one (`CS.member` cs)
      Bol      -> if i == 0 then k i caps else Nothing
      Eol      -> if i == len then k i caps else Nothing
      Seq []     -> k i caps
      Seq (x:xs) -> m x i caps (\j c -> m (Seq xs) j c k)
      Alt bs   -> firstJust [m b i caps k | b <- bs]
      Group g x -> m x i caps (\j c -> k j (M.insert g (i, j) c))
      Repeat lo hi x -> rep x lo hi i (0 :: Int) caps k
      where
        one p | i < len && p (B.index s i) = k (i + 1) caps
              | otherwise = Nothing

    rep x lo hi i count caps k
      | count < lo = m x i caps (\j c -> rep x lo hi j (count + 1) c k)
      | Just count == hi = k i caps
      | otherwise =
          case m x i caps (\j c -> if j == i then k j c else rep x lo hi j (count + 1) c k) of
            Just r  -> Just r
            Nothing -> k i caps

    firstJust xs = case [r | Just r <- xs] of
      (r:_) -> Just r
      []    -> Nothing
