-- |
-- Module      : RRule.Format
-- Description : Rendering of date-times as @YYYYMMDDTHHMMSS@.
module RRule.Format
  ( formatDateTime
  , dateTimeBuilder
  ) where

import Data.ByteString.Builder (Builder, char7)
import RRule.Types (DateTime (..))

-- | Render as @YYYYMMDDTHHMMSS@ (zero padded).
formatDateTime :: DateTime -> String
formatDateTime (DateTime y mo d h mi s) =
  pad 4 y ++ pad 2 mo ++ pad 2 d ++ "T" ++ pad 2 h ++ pad 2 mi ++ pad 2 s

pad :: Int -> Int -> String
pad w n = let t = show n in replicate (w - length t) '0' ++ t

-- | Same text as 'formatDateTime', as a 'Builder' (used by the CLI for speed).
dateTimeBuilder :: DateTime -> Builder
dateTimeBuilder (DateTime y mo d h mi s) =
  digits 4 y <> digits 2 mo <> digits 2 d <> char7 'T' <> digits 2 h <> digits 2 mi <> digits 2 s
  where
    digits :: Int -> Int -> Builder
    digits 4 n = digits 2 (n `quot` 100) <> digits 2 (n `rem` 100)
    digits _ n = char7 (dig (n `quot` 10)) <> char7 (dig (n `rem` 10))
    dig k = toEnum (48 + k)
