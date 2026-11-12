-- |
-- Module      : Text.Regex.Backtrack
-- Description : A backtracking regular-expression engine with capture spans.
--
-- >>> import Text.Regex.Backtrack
-- >>> let Right re = compile "(a|ab)(c|bcd)(d*)"
-- >>> match re "abcd"
-- Just (Match {matchStart = 0, matchEnd = 4, matchGroups = [Just (0,1),Just (1,4),Just (4,4)]})
--
-- The engine implements a small Perl-style subset (see the README for the
-- syntax) with leftmost, greedy, ordered-choice semantics. Subjects are
-- treated as sequences of bytes (characters above @\\255@ never match), and all
-- offsets are byte offsets.
module Text.Regex.Backtrack
  ( -- * Compiling
    Regex
  , compile
  , compileOrError
  , ParseError (..)
  , groupCount
    -- * Matching
  , Match (..)
  , match
  , matchBytes
  , matches
    -- * Extracting text
  , matchedText
  , groupText
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import Text.Regex.Backtrack.Matcher
import Text.Regex.Backtrack.Parser
import Text.Regex.Backtrack.Syntax (Pattern)

-- | A compiled pattern. Compile once, match many subjects.
newtype Regex = Regex Program

-- | Parse and compile a pattern.
compile :: String -> Either ParseError Regex
compile src = fromPattern <$> parseRegex src

-- | Like 'compile' but calls 'error' on a syntax error. Convenient for
-- literal patterns known to be valid.
compileOrError :: String -> Regex
compileOrError src = case compile src of
  Right re -> re
  Left (ParseError off msg) ->
    error ("Text.Regex.Backtrack.compileOrError: " ++ msg ++ " at offset " ++ show off)

fromPattern :: Pattern -> Regex
fromPattern = Regex . compileProgram

-- | Number of capture groups in the pattern.
groupCount :: Regex -> Int
groupCount (Regex p) = programGroups p

-- | Find the first match in a subject (start positions are tried left to right).
match :: Regex -> String -> Maybe Match
match re = matchBytes re . BC.pack

-- | 'match' on a strict 'B.ByteString' (no copying).
matchBytes :: Regex -> B.ByteString -> Maybe Match
matchBytes (Regex p) = execProgram p

-- | Does the pattern match anywhere in the subject?
matches :: Regex -> String -> Bool
matches re = maybe False (const True) . match re

-- | The text of the whole match.
matchedText :: B.ByteString -> Match -> B.ByteString
matchedText s m = slice s (matchStart m, matchEnd m)

-- | The text captured by group @n@ (1-based), if it is set.
groupText :: B.ByteString -> Match -> Int -> Maybe B.ByteString
groupText s m n
  | n < 1 || n > length gs = Nothing
  | otherwise = slice s <$> (gs !! (n - 1))
  where gs = matchGroups m

slice :: B.ByteString -> (Int, Int) -> B.ByteString
slice s (a, b) = B.take (b - a) (B.drop a s)
