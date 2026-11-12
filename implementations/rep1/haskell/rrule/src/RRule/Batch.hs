-- |
-- Module      : RRule.Batch
-- Description : The line-oriented batch format used by the command-line tool.
--
-- Each input line is @\<DTSTART\> \<RRULE\> \<N\>@; the corresponding output
-- line lists at most @N@ occurrences separated by single spaces.
module RRule.Batch
  ( processLine
  , processInput
  ) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Char (isDigit)
import Data.List (intersperse)
import RRule.Expand (occurrences)
import RRule.Format (dateTimeBuilder)
import RRule.Parse (parseDateTime, parseRule)

-- | Expand one input line into one output line (without the line feed).
processLine :: String -> Either String B.Builder
processLine line = case words line of
  [dt, rr, n]
    | not (null n) && all isDigit n -> do
        start <- parseDateTime dt
        rule <- parseRule rr
        let limit = read n :: Int
        Right (mconcat (intersperse (B.char7 ' ') (map dateTimeBuilder (take limit (occurrences start rule)))))
  _ -> Left ("malformed input line: " ++ show line)

-- | Process a whole input text, one output line (LF-terminated) per input
-- line.  A final missing LF in the input is fine.
processInput :: BL.ByteString -> Either String B.Builder
processInput input = fmap mconcat (mapM one (BL.lines input))
  where
    one l = fmap (<> B.char7 '\n') (processLine (BL.unpack l))
