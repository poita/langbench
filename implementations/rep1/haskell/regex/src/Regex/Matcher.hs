{-# LANGUAGE BangPatterns #-}
-- | Compilation of a syntax tree into a backtracking matcher.
--
-- The matcher is a direct implementation of the continuation-passing
-- definition @m(node, i, k)@: each node becomes a function that, given a
-- position and a continuation, tries every way of matching in order and
-- calls the continuation for each.  Capture writes are undone, one group
-- at a time, when the continuation fails, so abandoned paths cost
-- only as much as the writes they made.
module Regex.Matcher
  ( Env (..)
  , Matcher
  , compileNode
  ) where

import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

import qualified Regex.CharSet as CS
import Regex.Syntax

-- | The per-search environment.  @caps@ holds @2*g@ and @2*g+1@ for the
-- start and end of group @g@ (0-based index @g-1@ stored at @2*(g-1)@);
-- -1 means unset.
data Env = Env
  { envSubject :: !B.ByteString
  , envLength  :: !Int
  , envCaps    :: !(IOUArray Int Int)
  }

-- | A continuation receives the end position of a partial match.
type K = Int -> IO Bool

-- | @matcher env i k@ tries to match from position @i@ calling @k@ for each
-- way it can end.  Returns True as soon as a continuation does.
type Matcher = Env -> Int -> K -> IO Bool

compileNode :: Node -> Matcher
compileNode node = case node of
  Lit c      -> single (== c)
  AnyChar    -> single (const True)
  Set s      -> single (`CS.member` s)
  Bol        -> \_ i k -> if i == 0 then k i else pure False
  Eol        -> \env i k -> if i == envLength env then k i else pure False
  Seq xs     -> compileSeq (merge xs)
  Alt xs     -> compileAlt (map compileNode xs)
  Group g x  -> compileGroup (2 * (g - 1)) (compileNode x)
  Repeat lo hi x -> compileRepeat lo hi x
  where
    single p = \env i k ->
      if i < envLength env && p (BU.unsafeIndex (envSubject env) i)
        then k (i + 1) else pure False

-- Runs of literal characters are matched as one unit.
data Item = Run !B.ByteString | Other Node

merge :: [Node] -> [Item]
merge [] = []
merge (Lit c : rest) =
  let (lits, rest') = spanLits rest
  in Run (B.pack (c : lits)) : merge rest'
  where
    spanLits (Lit d : ys) = let (ds, zs) = spanLits ys in (d : ds, zs)
    spanLits ys           = ([], ys)
merge (n : rest) = Other n : merge rest

compileSeq :: [Item] -> Matcher
compileSeq [] = \_ i k -> k i
compileSeq [it] = compileItem it
compileSeq (it : rest) =
  let m1 = compileItem it
      m2 = compileSeq rest
  in \env i k -> m1 env i (\j -> m2 env j k)

compileItem :: Item -> Matcher
compileItem (Other n) = compileNode n
compileItem (Run bs) =
  let !n = B.length bs
  in \env i k ->
       if i + n <= envLength env && B.isPrefixOf bs (BU.unsafeDrop i (envSubject env))
         then k (i + n) else pure False

compileAlt :: [Matcher] -> Matcher
compileAlt [m] = m
compileAlt ms = \env i k ->
  let go [] = pure False
      go (m : rest) = do
        r <- m env i k
        if r then pure True else go rest
  in go ms

compileGroup :: Int -> Matcher -> Matcher
compileGroup !slot m = \env i k ->
  let caps = envCaps env in
  m env i $ \j -> do
    os <- unsafeRead caps slot
    oe <- unsafeRead caps (slot + 1)
    unsafeWrite caps slot i
    unsafeWrite caps (slot + 1) j
    r <- k j
    if r then pure True else do
      unsafeWrite caps slot os
      unsafeWrite caps (slot + 1) oe
      pure False

-- | Greedy repetition.
compileRepeat :: Int -> Maybe Int -> Node -> Matcher
compileRepeat lo hi x = case (hi, singleTest x) of
  (Just 0, _)  -> \_ i k -> k i
  (_, Just p)  -> repeatSingle lo hi p
  _            -> repeatGeneral lo hi (compileNode x)

-- | A node that always consumes exactly one character and touches no captures.
singleTest :: Node -> Maybe (Word8 -> Bool)
singleTest n = case n of
  Lit c   -> Just (== c)
  AnyChar -> Just (const True)
  Set s   -> Just (`CS.member` s)
  _       -> Nothing

-- | Equivalent to the general rule for one-character atoms: take as many as
-- possible (up to the maximum), then give them back one at a time.
repeatSingle :: Int -> Maybe Int -> (Word8 -> Bool) -> Matcher
repeatSingle lo hi p = \env i k ->
  let !len = envLength env
      !s = envSubject env
      !limit = case hi of
        Nothing -> len
        Just h  -> min len (i + h)
      scan !j | j < limit && p (BU.unsafeIndex s j) = scan (j + 1)
              | otherwise = j
      !end = scan i
      back !j
        | j < i + lo = pure False
        | otherwise = do
            r <- k j
            if r then pure True else back (j - 1)
  in back end

-- | The general rule @rep(x, min, max, i, count, k)@ from the definition.
repeatGeneral :: Int -> Maybe Int -> Matcher -> Matcher
repeatGeneral lo hi mx = \env i0 k0 ->
  let go !i !count k
        | count < lo = mx env i (\j -> go j (count + 1) k)
        | Just count == hi = k i
        | otherwise = do
            r <- mx env i (\j -> if j == i then k j else go j (count + 1) k)
            if r then pure True else k i
  in go i0 (0 :: Int) k0
