-- | The @LIKE@ wildcard matcher.
module MiniSQL.Like (likeMatch) where

import Data.Text (Text)
import qualified Data.Text as T

-- | @likeMatch pattern subject@: @%@ matches any run of characters, @_@
-- exactly one, anything else itself; the whole subject must match. ASCII
-- letters compare case-insensitively, every other character exactly.
--
-- This is the classic linear-scan matcher that remembers a single backtrack
-- point (the most recent @%@), so it runs in O(|subject| * |pattern|) worst
-- case and never builds a regular expression.
likeMatch :: Text -> Text -> Bool
likeMatch pat subj = go (T.unpack subj) (T.unpack pat) Nothing
  where
    go s p back = case p of
      '%' : ps -> go s ps (Just (s, ps))
      c : ps
        | (x : xs) <- s, c == '_' || fold c == fold x -> go xs ps back
      [] | null s -> True
      _ -> case back of
        Just (_ : bs, bp) -> go bs bp (Just (bs, bp))
        _ -> False

    fold c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise = c
