{-# LANGUAGE BangPatterns #-}
-- | Total-fit (Knuth–Plass style) line breaking over a horizontal list.
--
-- A list is first 'prepare'd (prefix sums make measuring any candidate line
-- O(1)); it can then be measured ('naturalWidth', 'minLineWidth') and broken
-- ('breakPrepared') from the same preparation.
module Typeset.Break
  ( BreakParams (..)
  , Prepared
  , Breaking (..)
  , prepare
  , preparedItems
  , naturalWidth
  , minLineWidth
  , breakPrepared
  , lineWYZ
  ) where

import Control.Monad
import Control.Monad.ST
import Data.Array
import Data.Array.ST
import Data.Array.Unboxed (UArray)
import qualified Data.Array.Unboxed as U
import Data.STRef

import Typeset.HList
import Typeset.Units

-- | The settings that influence line breaking.
data BreakParams = BreakParams
  { bpTolerance :: !Int
  , bpLinePenalty :: !Int
  , bpAdjDemerits :: !Int
  , bpDoubleHyphen :: !Int
  , bpFinalHyphen :: !Int
  }

-- | A horizontal list with the arrays needed for O(1) line measurement.
data Prepared = Prepared
  { pItems :: Array Int Item
  , pCount :: !Int
  , pW, pY, pZ, pInf :: UArray Int Int   -- ^ prefix sums over items @[0, i)@
  , pNext :: UArray Int Int              -- ^ next non-glue index at or after @i@
  , pPre :: UArray Int Int               -- ^ pre-break width of item @i@
  , pPen :: UArray Int Int               -- ^ breakpoint penalty of item @i@
  , pFlag :: UArray Int Bool             -- ^ breakpoint flagged?
  , pBreaks :: [Int]                     -- ^ breakpoints, ascending (excluding 0)
  }

-- | The result of breaking a list.
data Breaking = Breaking
  { brBreaks :: [Int]      -- ^ chosen breakpoints in order (the last is the final one)
  , brTotal :: !Int        -- ^ total demerits of the chosen breaking
  , brEmergency :: !Bool   -- ^ whether pass 2 was needed
  }

preparedItems :: Prepared -> Array Int Item
preparedItems = pItems

-- | Precompute the arrays for a list.
prepare :: Array Int Item -> Prepared
prepare items = Prepared items n pw py pz pinf nxt pre pen flg brks
  where
    n = snd (bounds items) + 1
    es = elems items
    pref f = U.listArray (0, n) (scanl (+) 0 (map f es)) :: UArray Int Int
    pw = pref (\it -> case it of
                 IBox b -> bxW b
                 IRigidBox w -> w
                 IGlue w _ _ _ -> w
                 IPenalty {} -> 0)
    py = pref (\it -> case it of IGlue _ y _ _ -> y; _ -> 0)
    pz = pref (\it -> case it of IGlue _ _ z _ -> z; _ -> 0)
    pinf = pref (\it -> case it of IGlue _ _ _ True -> 1; _ -> 0)
    isGlue it = case it of IGlue {} -> True; _ -> False
    nxt = U.listArray (0, n) (foldr (\(i, g) acc -> case acc of
                                         (nv : _) -> (if g then nv else i) : acc
                                         [] -> [i])
                                   [n] (zip [0 ..] (map isGlue es))) :: UArray Int Int
    pre = U.listArray (0, n - 1) [ case it of IPenalty _ _ (Just b) -> bxW b; _ -> 0 | it <- es ] :: UArray Int Int
    isBp i it = case it of
      IGlue {} -> i > 0 && (case items ! (i - 1) of IBox _ -> True; _ -> False)
      IPenalty p _ _ -> p < 10000
      _ -> False
    pen = U.listArray (0, n - 1) [ case it of IPenalty p _ _ -> p; _ -> 0 | it <- es ] :: UArray Int Int
    flg = U.listArray (0, n - 1) [ case it of IPenalty _ f _ -> f; _ -> False | it <- es ] :: UArray Int Bool
    brks = [ i | (i, it) <- zip [0 ..] es, isBp i it ]

-- | (W, Y, Z, has-infinite-glue) of the line between breakpoints @a < b@.
lineWYZ :: Prepared -> Int -> Int -> (Int, Int, Int, Bool)
lineWYZ p a b =
  let s = min b (pNext p U.! (if a == 0 then 0 else a + 1))
      w = pW p U.! b - pW p U.! s + pPre p U.! b
      y = pY p U.! b - pY p U.! s
      z = pZ p U.! b - pZ p U.! s
      inf = pInf p U.! b - pInf p U.! s > 0
  in (w, y, z, inf)
{-# INLINE lineWYZ #-}

-- | The natural width of the whole list on one line (the final infinite
-- glue has width 0).
naturalWidth :: Prepared -> Int
naturalWidth p = pW p U.! pCount p

-- | The widest line between any two consecutive breakpoints (including the
-- start and the final breakpoint).
minLineWidth :: Prepared -> Int
minLineWidth p = maximum (0 : [ w | (a, b) <- zip pts (drop 1 pts), let (w, _, _, _) = lineWYZ p a b ])
  where pts = 0 : pBreaks p

-- | Line metrics: kind (0 ok, 1 unstretchable, 2 overfull), badness, fitness.
data LM = LM !Int !Int !Int

lineMetrics :: Int -> Int -> Int -> Int -> Bool -> LM
lineMetrics l w y z inf
  | d >= 0 && inf = LM 0 0 1
  | d == 0 = LM 0 0 1
  | d > 0 = if y == 0 then LM 1 10000 3
            else LM 0 (min 10000 (cube100Div d y)) (if d > y then 3 else if 2 * d > y then 2 else 1)
  | otherwise = let e = negate d
                in if z == 0 || e > z then LM 2 10000 0
                   else LM 0 (min 10000 (cube100Div e z)) (if 2 * e > z then 0 else 1)
  where d = l - w
{-# INLINE lineMetrics #-}

-- | Break a prepared list at the given measure; the first line is shortened
-- by @firstIndent@.
breakPrepared :: BreakParams -> Prepared -> Int -> Int -> Breaking
breakPrepared bp p measure firstIndent =
  case runPass False of
    Just (bs, t) -> Breaking bs t False
    Nothing -> case runPass True of
      Just (bs, t) -> Breaking bs t True
      Nothing -> Breaking [pCount p - 1] 0 True   -- unreachable: pass 2 always succeeds
  where
    final = pCount p - 1
    brks = pBreaks p
    maxNodes = 4 * (length brks + 1) + 2
    runPass :: Bool -> Maybe ([Int], Int)
    runPass pass2 = runST $ do
      nBp <- newArray (0, maxNodes) 0 :: ST s (STUArray s Int Int)
      nCls <- newArray (0, maxNodes) 1 :: ST s (STUArray s Int Int)
      nTot <- newArray (0, maxNodes) 0 :: ST s (STUArray s Int Int)
      nPrev <- newArray (0, maxNodes) (-1) :: ST s (STUArray s Int Int)
      count <- newSTRef (1 :: Int)
      active <- newSTRef [0 :: Int]
      let loop [] = return ()
          loop (b : rest) = do
            act <- readSTRef active
            unless (null act) $ do
              let pen = pPen p U.! b
                  flagB = pFlag p U.! b
                  isFinal = b == final
              -- evaluate every active node
              (kept, best) <- evalNodes act b pen flagB isFinal
              -- create nodes in class order
              c0 <- readSTRef count
              let mk !c !k !acc [] = return (c, reverse acc, k)
                  mk !c !k !acc ((cls, tot, pr) : more)
                    | pr < 0 = mk c k acc more
                    | otherwise = do
                        writeArray nBp c b
                        writeArray nCls c cls
                        writeArray nTot c tot
                        writeArray nPrev c pr
                        mk (c + 1) (k + 1) (c : acc) more
              (c1, newIds, _) <- mk c0 (0 :: Int) [] best
              writeSTRef count c1
              writeSTRef active (kept ++ newIds)
              loop rest
          evalNodes act b pen flagB isFinal = go act [] (B4 inf4 inf4 inf4 inf4)
            where
              go [] keptRev bst = return (reverse keptRev, bestList bst)
              go (nd : more) keptRev bst = do
                a <- readArray nBp nd
                c0 <- readArray nCls nd
                t0 <- readArray nTot nd
                let l = measure - (if a == 0 then firstIndent else 0)
                    (w, y, z, inf) = lineWYZ p a b
                    wNoPre = w - pPre p U.! b
                    prune = not pass2 && wNoPre - l > z
                    LM kind bad fit = lineMetrics l w y z inf
                    feasible = pass2 || (kind == 0 && bad <= bpTolerance bp)
                    flag0 = a /= 0 && pFlag p U.! a
                    dem = (bpLinePenalty bp + bad) ^ (2 :: Int)
                          + (if pen >= 0 && pen < 10000 then pen * pen
                             else if pen > -10000 && pen < 0 then negate (pen * pen) else 0)
                          + (if flagB && flag0 then bpDoubleHyphen bp else 0)
                          + (if abs (fit - c0) > 1 then bpAdjDemerits bp else 0)
                          + (if isFinal && flag0 then bpFinalHyphen bp else 0)
                    tot = t0 + dem
                    keptRev' = if prune then keptRev else nd : keptRev
                    bst' = if feasible then upd fit tot nd bst else bst
                go more keptRev' bst'
      loop brks
      cnt <- readSTRef count
      -- find the best node at the final breakpoint
      let pick !i !bestI !bestT
            | i >= cnt = return bestI
            | otherwise = do
                bpI <- readArray nBp i
                if bpI /= final then pick (i + 1) bestI bestT
                else do
                  t <- readArray nTot i
                  if bestI < 0 || t < bestT then pick (i + 1) i t else pick (i + 1) bestI bestT
      bestI <- pick 1 (-1) 0
      if bestI < 0 then return Nothing else do
        tot <- readArray nTot bestI
        let chain i acc
              | i <= 0 = return acc
              | otherwise = do
                  b <- readArray nBp i
                  pr <- readArray nPrev i
                  chain pr (b : acc)
        bs <- chain bestI []
        return (Just (bs, tot))

-- | Best (total, predecessor) per fitness class.
data B4 = B4 !(Int, Int) !(Int, Int) !(Int, Int) !(Int, Int)

inf4 :: (Int, Int)
inf4 = (maxBound, -1)

upd :: Int -> Int -> Int -> B4 -> B4
upd cls tot nd (B4 a b c d) = case cls of
  0 -> B4 (cmp a) b c d
  1 -> B4 a (cmp b) c d
  2 -> B4 a b (cmp c) d
  _ -> B4 a b c (cmp d)
  where cmp cur@(t, _) = if tot < t then (tot, nd) else cur

bestList :: B4 -> [(Int, Int, Int)]
bestList (B4 (t0, p0) (t1, p1) (t2, p2) (t3, p3)) =
  [ (0, t0, p0), (1, t1, p1), (2, t2, p2), (3, t3, p3) ]
