-- | A deliberately naive, purely functional transcription of section 3 of
-- the specification, used as an oracle for the optimised matcher. Captures
-- are an immutable map, so "undoing" a failed path is simply discarding it.
module Reference (refMatch) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M

import Text.Regex.Backtrack (Match (..))
import qualified Text.Regex.Backtrack.CharSet as CS
import Text.Regex.Backtrack.Syntax

type Caps = M.Map Int (Int, Int)

-- | Continuation: position and captures to an overall result.
type K r = Int -> Caps -> Maybe r

refMatch :: Pattern -> B.ByteString -> Maybe Match
refMatch (Pattern node g) subj = go 0
  where
    s = BC.unpack subj
    len = length s
    go start
      | start > len = Nothing
      | otherwise = case m node start M.empty (\j caps -> Just (j, caps)) of
          Just (j, caps) ->
            Just (Match start j [M.lookup k caps | k <- [1 .. g]])
          Nothing -> go (start + 1)

    charAt i = s !! i

    m :: Node -> Int -> Caps -> K r -> Maybe r
    m node' i caps k = case node' of
      Literal c   -> if i < len && charAt i == c then k (i + 1) caps else Nothing
      AnyChar     -> if i < len then k (i + 1) caps else Nothing
      Class cs    -> if i < len && CS.member (charAt i) cs then k (i + 1) caps else Nothing
      StartAnchor -> if i == 0 then k i caps else Nothing
      EndAnchor   -> if i == len then k i caps else Nothing
      Seq []      -> k i caps
      Seq (x : xs) -> m x i caps (\j c -> m (Seq xs) j c k)
      Alt bs      -> firstJust [m b i caps k | b <- bs]
      Group n x   -> m x i caps (\j c -> k j (M.insert n (i, j) c))
      Repeat mn mx x -> rep x mn mx i (0 :: Int) caps k

    rep x mn mx i count caps k
      | count < mn = m x i caps (\j c -> rep x mn mx j (count + 1) c k)
      | Just count == mx = k i caps
      | otherwise =
          case m x i caps (\j c -> if j == i then k j c
                                   else rep x mn mx j (count + 1) c k) of
            Just r  -> Just r
            Nothing -> k i caps

    firstJust xs = case [r | Just r <- xs] of
      (r : _) -> Just r
      []      -> Nothing
