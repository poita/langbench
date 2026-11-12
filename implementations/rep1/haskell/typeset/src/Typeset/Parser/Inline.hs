-- | The inline scanner: turns the text of one block, with source positions,
-- into 'INode's and reports the first inline error.
module Typeset.Parser.Inline
  ( CP (..)
  , scanInline
  , joinLines
  , charsAt
  ) where

import Typeset.Error
import Typeset.Syntax

-- | A character with its source position (1-based line and column).
data CP = CP !Char !Int !Int

-- | The characters of a line starting at column @col@, with positions.
charsAt :: Int -> Int -> String -> [CP]
charsAt ln col s = zipWith (\i c -> CP c ln i) [col ..] s

-- | Join the lines of a block with one space between consecutive lines.
joinLines :: [[CP]] -> [CP]
joinLines [] = []
joinLines [l] = l
joinLines (l : ls) = l ++ [sp l] ++ joinLines ls
  where
    sp [] = CP ' ' 0 0
    sp xs = case last xs of CP _ ln c -> CP ' ' ln (c + 1)

err :: Int -> Int -> ErrorCode -> Either Error a
err l c code = Left (Error DocumentFile l c code)

-- | Scan inline text.  The flag says whether footnotes are allowed; the
-- integer is the number of footnotes seen so far, and the result carries the
-- updated count.
scanInline :: Bool -> Int -> [CP] -> Either Error ([INode], Int)
scanInline allowNote n0 cps = do
  (nodes, n, rest) <- go False n0 cps
  case rest of
    [] -> Right (nodes, n)
    (CP _ l c : _) -> err l c StrayBrace
  where
    -- Parse a sequence up to an unmatched '}' (left unconsumed) or the end.
    go :: Bool -> Int -> [CP] -> Either Error ([INode], Int, [CP])
    go inNote = loop []
      where
        loop acc n [] = Right (reverse acc, n, [])
        loop acc n r@(CP c l col : rest) = case c of
          '}' -> Right (reverse acc, n, r)
          ' ' -> loop (ISpace : acc) n rest
          '~' -> loop (IRigid : acc) n rest
          '\\' -> case rest of
            [] -> err l col BadEscape
            (CP d _ _ : rest') -> case d of
              ' ' -> loop (IRigid : acc) n rest'
              '-' -> loop (IDisc : acc) n rest'
              _ | d `elem` "{}|\\@~" -> loop (IChar d : acc) n rest'
                | otherwise -> err l col BadEscape
          '{' -> case rest of
            (CP t _ _ : CP '|' _ _ : body) | t `elem` "bim+-n" -> do
              tag <- if t == 'n'
                       then if inNote then err l col NestedFootnote
                            else if not allowNote then err l col FootnoteNotAllowed
                            else Right Nothing
                       else Right (Just (styleOf t))
              case tag of
                Nothing -> do
                  let k = n + 1
                  (inner, n', r') <- go True k body
                  r'' <- close l col r'
                  loop (INote k inner : acc) n' r''
                Just st -> do
                  (inner, n', r') <- go inNote n body
                  r'' <- close l col r'
                  loop (IStyle st inner : acc) n' r''
            _ -> err l col UnknownInline
          _ -> loop (IChar c : acc) n rest
    close _ _ (CP '}' _ _ : r) = Right r
    close l c _ = err l c UnclosedInline
    styleOf t = case t of
      'b' -> TagBold
      'i' -> TagItalic
      'm' -> TagMono
      '+' -> TagLarger
      _ -> TagSmaller
