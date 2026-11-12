-- | A backtracking regular-expression engine with Perl-style semantics.
--
-- Matching is leftmost, greedy and ordered-choice, and reports the position
-- of every capture group.  A group inside a repetition keeps the value of
-- its last completed iteration; groups not on the successful path are unset.
--
-- > ghci> let Right re = compile "(a|(b))+"
-- > ghci> search re (Data.ByteString.Char8.pack "ba")
-- > Just (Match {matchStart = 0, matchEnd = 2, matchGroups = [Just (1,2),Just (0,1)]})
--
-- Subjects are byte strings; patterns are 'String's whose characters must
-- lie in U+0000..U+00FF.  A compiled 'Regex' is immutable and may be shared
-- freely between threads.
module Regex
  ( -- * Compiling
    Regex
  , compile
  , ParseError (..)
  , pattern
  , groupCount
    -- * Matching
  , Match (..)
  , search
  , matches
  ) where

import Control.Monad (forM)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray, newArray)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import System.IO.Unsafe (unsafeDupablePerformIO)

import Regex.Analysis (firstChars, startAnchored)
import qualified Regex.CharSet as CS
import Regex.Matcher
import Regex.Parser (ParseError (..), parsePattern)
import qualified Regex.Syntax as S

-- | A compiled pattern.
data Regex = Regex
  { pattern     :: String
    -- ^ the source text
  , groupCount  :: !Int
    -- ^ number of capture groups
  , reMatcher   :: Matcher
  , reAnchored  :: !Bool
  , reNullable  :: !Bool
  , reFirst     :: !CS.CharSet
  }

instance Show Regex where
  showsPrec d r = showParen (d > 10) $ showString "compile " . shows (pattern r)

-- | The result of a successful search.  Offsets are 0-based, with exclusive
-- ends.
data Match = Match
  { matchStart  :: !Int
  , matchEnd    :: !Int
  , matchGroups :: [Maybe (Int, Int)]
    -- ^ one entry per group, in order of opening parenthesis
  } deriving (Eq, Show)

-- | Parse and compile a pattern.
compile :: String -> Either ParseError Regex
compile src = do
  tree <- parsePattern src
  let (firsts, nullable) = firstChars tree
  pure Regex
    { pattern    = src
    , groupCount = S.groupCount tree
    , reMatcher  = compileNode tree
    , reAnchored = startAnchored tree
    , reNullable = nullable
    , reFirst    = firsts
    }

-- | Find the first match: start positions are tried left to right, and at
-- each the pattern's own priorities decide the match.
search :: Regex -> B.ByteString -> Maybe Match
search re subject = unsafeDupablePerformIO $ do
  let g = groupCount re
      len = B.length subject
      endSlot = 2 * g
  caps <- newArray (0, endSlot) (-1) :: IO (IOUArray Int Int)
  let env = Env subject len caps
      finish j = unsafeWrite caps endSlot j >> pure True
      canStart s
        | reNullable re = True
        | s < len = BU.unsafeIndex subject s `CS.member` reFirst re
        | otherwise = False
      lastStart = if reAnchored re then 0 else len
      loop s
        | s > lastStart = pure Nothing
        | not (canStart s) = loop (s + 1)
        | otherwise = do
            ok <- reMatcher re env s finish
            if ok then Just <$> collect s else loop (s + 1)
      collect s = do
        e <- unsafeRead caps endSlot
        gs <- forM [0 .. g - 1] $ \i -> do
          a <- unsafeRead caps (2 * i)
          b <- unsafeRead caps (2 * i + 1)
          pure (if a < 0 then Nothing else Just (a, b))
        pure (Match s e gs)
  loop 0

-- | Does the pattern match anywhere in the subject?
matches :: Regex -> B.ByteString -> Bool
matches re = maybe False (const True) . search re
