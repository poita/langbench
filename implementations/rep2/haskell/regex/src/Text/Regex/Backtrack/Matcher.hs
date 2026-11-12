{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Text.Regex.Backtrack.Matcher
-- Description : Compile a syntax tree to a backtracking matcher and run it.
--
-- The matcher is a direct transcription of the continuation-passing
-- definition @m(node, i, k)@: every node is compiled once into a closure that
-- takes the current position and a continuation, and tries its alternatives
-- depth-first in order. Capture writes go to a mutable array and are undone
-- when the continuation fails, so the cost of undoing is proportional to the
-- writes made, not to the number of groups.
module Text.Regex.Backtrack.Matcher
  ( Program
  , Match (..)
  , compileProgram
  , programGroups
  , execProgram
  ) where

import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray, newArray)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Char (ord)
import Data.Word (Word8)
import System.IO.Unsafe (unsafeDupablePerformIO)

import Text.Regex.Backtrack.Analysis (firstChars, startAnchored)
import Text.Regex.Backtrack.CharSet (CharSet)
import qualified Text.Regex.Backtrack.CharSet as CS
import Text.Regex.Backtrack.Syntax

-- | A successful match.
data Match = Match
  { matchStart  :: !Int
    -- ^ Start offset of the whole match.
  , matchEnd    :: !Int
    -- ^ Exclusive end offset of the whole match.
  , matchGroups :: [Maybe (Int, Int)]
    -- ^ One entry per capture group, in order; 'Nothing' if unset.
  } deriving (Eq, Show)

-- Per-run environment: the subject and the capture table. The table holds
-- @2*G@ slots (start/end per group, -1 when unset) plus one slot for the
-- end of the overall match.
data Env = Env
  { envSubject :: !B.ByteString
  , envLen     :: !Int
  , envCaps    :: !(IOUArray Int Int)
  }

type Cont = Int -> IO Bool
type M = Env -> Int -> Cont -> IO Bool

-- | A compiled pattern.
data Program = Program
  { progGroups   :: !Int
  , progMatcher  :: M
  , progAnchored :: !Bool
  , progFirst    :: !(Maybe CharSet)
  }

-- | Number of capture groups in the program.
programGroups :: Program -> Int
programGroups = progGroups

-- | Compile a parsed pattern.
compileProgram :: Pattern -> Program
compileProgram (Pattern node g) = Program
  { progGroups   = g
  , progMatcher  = compileNode node
  , progAnchored = startAnchored node
  , progFirst    = firstChars node
  }

-- | Search a subject for the first match. The result is a pure function of
-- the inputs: all mutation is confined to a private capture table.
execProgram :: Program -> B.ByteString -> Maybe Match
execProgram prog subj = unsafeDupablePerformIO $ do
  let g   = progGroups prog
      len = B.length subj
  caps <- newArray (0, 2 * g) (-1) :: IO (IOUArray Int Int)
  let env = Env subj len caps
      m   = progMatcher prog
      done :: Cont
      done j = unsafeWrite caps (2 * g) j >> pure True
      tryAt :: Int -> IO Bool
      tryAt !i = m env i done
      -- Failed attempts undo all their capture writes, so the table is
      -- back to "all unset" for the next start position.
      canStart i = case progFirst prog of
        Nothing -> True
        Just fs -> i < len && CS.memberByte (BU.unsafeIndex subj i) fs
      lastStart = if progAnchored prog then 0 else len
      searchFrom :: Int -> IO (Maybe Match)
      searchFrom !i
        | i > lastStart = pure Nothing
        | otherwise = do
            ok <- if canStart i then tryAt i else pure False
            if ok then Just <$> result i else searchFrom (i + 1)
      result :: Int -> IO Match
      result s = do
        e <- unsafeRead caps (2 * g)
        gs <- mapM (\k -> do
                      a <- unsafeRead caps (2 * k)
                      b <- unsafeRead caps (2 * k + 1)
                      pure (if a < 0 then Nothing else Just (a, b)))
                   [0 .. g - 1]
        pure (Match s e gs)
  searchFrom 0

-- ---------------------------------------------------------------------------
-- Compilation

compileNode :: Node -> M
compileNode node = case node of
  Literal c
    | ord c < 256 -> let w = fromIntegral (ord c) :: Word8
                     in single (== w)
    | otherwise   -> \_ _ _ -> pure False
  AnyChar   -> single (const True)
  Class s   -> single (`CS.memberByte` s)
  StartAnchor -> \_ i k -> if i == 0 then k i else pure False
  EndAnchor   -> \e i k -> if i == envLen e then k i else pure False
  Seq ns    -> foldr seq2 (\_ i k -> k i) (map compileNode ns)
  Alt ns    -> foldr1 alt2 (map compileNode ns)
  Group g n -> group (g - 1) (compileNode n)
  Repeat mn mx n -> case singlePred n of
    Just p  -> repeatSingle mn mx p
    Nothing -> repeatGeneral mn mx (compileNode n)

seq2 :: M -> M -> M
seq2 a b = \e i k -> a e i (\j -> b e j k)

alt2 :: M -> M -> M
alt2 a b = \e i k -> do
  r <- a e i k
  if r then pure True else b e i k

single :: (Word8 -> Bool) -> M
single p = \e i k ->
  if i < envLen e && p (BU.unsafeIndex (envSubject e) i) then k (i + 1) else pure False
{-# INLINE single #-}

-- m(group g: x, i, k)
group :: Int -> M -> M
group g mx = \e i k ->
  mx e i $ \j -> do
    let caps = envCaps e
    oldS <- unsafeRead caps (2 * g)
    oldE <- unsafeRead caps (2 * g + 1)
    unsafeWrite caps (2 * g) i
    unsafeWrite caps (2 * g + 1) j
    r <- k j
    if r then pure True else do
      unsafeWrite caps (2 * g) oldS
      unsafeWrite caps (2 * g + 1) oldE
      pure False

-- rep(x, min, max, i, count, k), transcribed from the specification.
repeatGeneral :: Int -> Maybe Int -> M -> M
repeatGeneral mn mx body = \e i0 k0 -> go e 0 i0 k0
  where
    limit = maybe maxBound id mx
    go e !count !i k
      | count < mn  = body e i (\j -> go e (count + 1) j k)
      | count == limit = k i
      | otherwise = do
          r <- body e i (\j -> if j == i then k j else go e (count + 1) j k)
          if r then pure True else k i

-- A node that always consumes exactly one character, as a byte predicate.
singlePred :: Node -> Maybe (Word8 -> Bool)
singlePred n = case n of
  Literal c | ord c < 256 -> let w = fromIntegral (ord c) in Just (== w)
            | otherwise   -> Just (const False)
  AnyChar -> Just (const True)
  Class s -> Just (`CS.memberByte` s)
  _       -> Nothing

-- Greedy repetition of a one-character matcher. Equivalent to 'repeatGeneral'
-- (no capture writes, no empty iterations): take the longest run allowed,
-- then give characters back one at a time down to the minimum.
repeatSingle :: Int -> Maybe Int -> (Word8 -> Bool) -> M
repeatSingle mn mx p = \e i k ->
  let len   = envLen e
      subj  = envSubject e
      hardEnd = case mx of
        Nothing -> len
        Just m  -> min len (i + m)
      scan !j | j < hardEnd && p (BU.unsafeIndex subj j) = scan (j + 1)
              | otherwise = j
      end = scan i
      lowest = i + mn
      back !j
        | j < lowest = pure False
        | otherwise = do
            r <- k j
            if r then pure True else back (j - 1)
  in when' (end >= lowest) (back end)
  where
    when' c a = if c then a else pure False
