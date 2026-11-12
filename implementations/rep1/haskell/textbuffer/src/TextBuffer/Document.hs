-- |
-- Module      : TextBuffer.Document
-- Description : A document as a sequence of lines.
--
-- A 'Document' always holds at least one line. Lines are strict byte
-- strings of printable ASCII, so a column is both a character and a byte
-- index. Splicing a range costs O(ℓ + m) for the affected line(s) plus
-- O(log L) for the sequence of lines.
module TextBuffer.Document
  ( Document
  , fromLines
  , toLines
  , fromText
  , toText
  , lineCount
  , lineAt
  , lineLength
  , clampPos
  , endOfDocument
  , slice
  , replace
  ) where

import qualified Data.ByteString.Char8 as B
import Data.Foldable (toList)
import Data.Sequence (Seq, (<|), (|>), (><))
import qualified Data.Sequence as Seq

import TextBuffer.Position

-- | A non-empty sequence of lines.
newtype Document = Document (Seq B.ByteString)
  deriving (Eq, Show)

-- | Build a document from its lines; an empty list yields one empty line.
fromLines :: [B.ByteString] -> Document
fromLines [] = Document (Seq.singleton B.empty)
fromLines ls = Document (Seq.fromList ls)

-- | The lines of the document (never empty).
toLines :: Document -> [B.ByteString]
toLines (Document s) = toList s

-- | Build a document from text whose lines are separated by @\\n@.
fromText :: B.ByteString -> Document
fromText = Document . Seq.fromList . B.split '\n'

-- | The document text: lines joined by single newlines.
toText :: Document -> B.ByteString
toText = B.intercalate (B.singleton '\n') . toLines

-- | Number of lines, @L ≥ 1@.
lineCount :: Document -> Int
lineCount (Document s) = Seq.length s

-- | The text of a line. The index must be in range.
lineAt :: Document -> Int -> B.ByteString
lineAt (Document s) i = Seq.index s i

-- | Length of a line. The index must be in range.
lineLength :: Document -> Int -> Int
lineLength d = B.length . lineAt d

-- | Clamp a (possibly out-of-range) position: the line first, then the
-- column within that line.
clampPos :: Document -> Pos -> Pos
clampPos d (Pos l c) = Pos l' (max 0 (min c (lineLength d l')))
  where l' = max 0 (min l (lineCount d - 1))

-- | The position just after the last character of the document.
endOfDocument :: Document -> Pos
endOfDocument d = Pos l (lineLength d l) where l = lineCount d - 1

-- | The text between two valid positions @start ≤ end@ (newlines included).
slice :: Pos -> Pos -> Document -> B.ByteString
slice (Pos sl sc) (Pos el ec) d@(Document s)
  | sl == el  = B.take (ec - sc) (B.drop sc (lineAt d sl))
  | otherwise = B.intercalate (B.singleton '\n') $
      B.drop sc (Seq.index s sl)
        : toList (Seq.take (el - sl - 1) (Seq.drop (sl + 1) s))
        ++ [B.take ec (Seq.index s el)]

-- | @replace start end text doc@ replaces the range @[start, end]@ by
-- @text@, which may contain newlines.
replace :: Pos -> Pos -> B.ByteString -> Document -> Document
replace (Pos sl sc) (Pos el ec) text (Document s)
  | sl == el, [single] <- pieces =
      Document (Seq.update sl (B.concat [prefix, single, B.drop ec first]) s)
  | otherwise = Document (pre >< (middle >< post))
  where
    pieces = if B.null text then [B.empty] else B.split '\n' text
    first = Seq.index s sl
    prefix = B.take sc first
    suffix = B.drop ec (Seq.index s el)
    (pre, rest) = Seq.splitAt sl s
    post = Seq.drop (el - sl + 1) rest
    middle = case pieces of
      [x] -> Seq.singleton (B.concat [prefix, x, suffix])
      xs  -> ((prefix `B.append` head xs) <| Seq.fromList (init (tail xs)))
               |> (last xs `B.append` suffix)
