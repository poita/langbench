-- | Byte-string helpers shared by the evaluator and the commands.
module Kiln.Text
  ( fileLines
  , unlinesBS
  , replaceAll
  , renderInt
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

-- | The lines of a file: none for empty content, otherwise the pieces between
-- newlines with the final empty piece (after a trailing newline) dropped.
-- Carriage returns are ordinary content.
fileLines :: B.ByteString -> [B.ByteString]
fileLines c
  | B.null c = []
  | otherwise = case B.split 10 c of
      ps | B.null (last ps) -> init ps
         | otherwise -> ps

-- | Concatenate each line followed by a newline.
unlinesBS :: [B.ByteString] -> B.ByteString
unlinesBS = B.concat . concatMap (\l -> [l, "\n"])

-- | Replace every occurrence of a non-empty pattern, scanning left to right
-- without overlap.
replaceAll :: B.ByteString -> B.ByteString -> B.ByteString -> B.ByteString
replaceAll from to s = B.concat (go s)
  where
    n = B.length from
    go rest =
      let (before, after) = B.breakSubstring from rest
       in if B.null after
            then [before]
            else before : to : go (B.drop n after)

renderInt :: Int -> B.ByteString
renderInt = BC.pack . show
