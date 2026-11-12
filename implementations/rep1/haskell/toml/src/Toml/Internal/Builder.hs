-- | Small helpers for producing UTF-8 output.
module Toml.Internal.Builder
  ( escapeText
  , hexEscape
  ) where

import Data.ByteString.Builder (Builder, string7)
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8Builder)

-- | @escapeText needs esc t@ writes @t@, replacing every character that
-- satisfies @needs@ by @esc c@.  The (usually long) runs between such
-- characters are copied as-is.
escapeText :: (Char -> Bool) -> (Char -> Builder) -> Text -> Builder
escapeText needs esc = go
  where
    go t =
      let (plain, rest) = T.break needs t
      in encodeUtf8Builder plain <> case T.uncons rest of
           Nothing -> mempty
           Just (c, rest') -> esc c <> go rest'

-- | A @\\u00xx@-style escape with four lowercase hex digits.
hexEscape :: Char -> Builder
hexEscape c = string7 ("\\u" ++ map digit [n `div` 4096, n `div` 256 `mod` 16, n `div` 16 `mod` 16, n `mod` 16])
  where
    n = ord c
    digit i = "0123456789abcdef" !! i
