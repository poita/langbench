{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : TextBuffer.Command
-- Description : The command language and its parser.
module TextBuffer.Command
  ( Command (..)
  , Direction (..)
  , parseCommand
  , decodeInsert
  ) where

import qualified Data.ByteString.Char8 as B

-- | Directions of the @move@ command.
data Direction = MoveLeft | MoveRight | MoveUp | MoveDown | MoveHome | MoveEnd
  deriving (Eq, Show, Enum, Bounded)

-- | A command of the buffer language.
data Command
  = Insert !B.ByteString
    -- ^ insert already-decoded text (may contain newlines) at every cursor
  | Delete
    -- ^ backspace
  | DeleteForward
  | Move !Direction !Bool
    -- ^ direction, and whether to extend the selection
  | Goto !Int !Int
  | AddCursor !Int !Int
  | ClearCursors
  | Undo
  | Redo
  | Print
  deriving (Eq, Show)

-- | Decode the argument of @insert@: @\\n@ becomes a newline and @\\\\@ a
-- single backslash. Returns 'Nothing' for a malformed escape.
decodeInsert :: B.ByteString -> Maybe B.ByteString
decodeInsert s
  | B.notElem '\\' s = Just s
  | otherwise        = B.concat <$> go s
  where
    go t = case B.elemIndex '\\' t of
      Nothing -> Just [t]
      Just i  -> case B.uncons (B.drop (i + 1) t) of
        Just ('n',  r) -> ([B.take i t, B.singleton '\n'] ++) <$> go r
        Just ('\\', r) -> ([B.take i t, B.singleton '\\'] ++) <$> go r
        _              -> Nothing

-- | Parse one command line (without its line terminator).
parseCommand :: B.ByteString -> Either String Command
parseCommand line
  | Just rest <- B.stripPrefix (B.pack "insert ") line =
      maybe (Left ("bad escape in: " ++ B.unpack line)) (Right . Insert)
            (decodeInsert rest)
  | otherwise = case words (B.unpack line) of
      ["delete"]            -> Right Delete
      ["delete-forward"]    -> Right DeleteForward
      ["move", d]           -> dir d False
      ["move", d, "select"] -> dir d True
      ["goto", l, c]        -> pair Goto l c
      ["add-cursor", l, c]  -> pair AddCursor l c
      ["clear-cursors"]     -> Right ClearCursors
      ["undo"]              -> Right Undo
      ["redo"]              -> Right Redo
      ["print"]             -> Right Print
      _                     -> bad
  where
    bad = Left ("unrecognised command: " ++ B.unpack line)
    dir d sel = case d of
      "left"  -> Right (Move MoveLeft sel)
      "right" -> Right (Move MoveRight sel)
      "up"    -> Right (Move MoveUp sel)
      "down"  -> Right (Move MoveDown sel)
      "home"  -> Right (Move MoveHome sel)
      "end"   -> Right (Move MoveEnd sel)
      _       -> bad
    pair k l c = case (readNat l, readNat c) of
      (Just l', Just c') -> Right (k l' c')
      _                  -> bad
    readNat s
      | not (null s), all (`elem` ['0' .. '9']) s = Just (read (take 18 s))
      | otherwise = Nothing
