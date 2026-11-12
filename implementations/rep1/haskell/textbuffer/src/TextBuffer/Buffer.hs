-- |
-- Module      : TextBuffer.Buffer
-- Description : The editing state: document, cursors, undo and redo.
--
-- A 'Buffer' is an immutable value; every operation returns a new buffer.
-- Each document-changing edit command pushes one undo entry holding the
-- cursors before and after the command and its replacements. Entries never
-- hold copies of the document.
module TextBuffer.Buffer
  ( Buffer
  , empty
  , fromLines
  , fromDocument
  , document
  , cursors
  , canUndo
  , canRedo
  , execute
  , undo
  , redo
  , render
  ) where

import Data.ByteString.Builder (Builder, byteString, char7, intDec)
import qualified Data.ByteString.Char8 as B

import TextBuffer.Command
import TextBuffer.Cursor
import TextBuffer.Document (Document)
import qualified TextBuffer.Document as Doc
import TextBuffer.Movement (moveCursor)
import TextBuffer.Position

-- | One replacement: at a start position (in the document as it was just
-- before this replacement was applied) the removed text was swapped for
-- the inserted text.
data Replacement = Replacement !Pos !B.ByteString !B.ByteString

-- | One undo step: a whole edit command.
data Entry = Entry
  { entryBefore :: [Cursor]
  , entryAfter  :: [Cursor]
  , entryReps   :: [Replacement]  -- ^ in application order
  }

-- | A document with its cursors and undo/redo history.
data Buffer = Buffer
  { bufDoc     :: !Document
  , bufCursors :: [Cursor]
  , bufUndo    :: [Entry]
  , bufRedo    :: [Entry]
  }

-- | A buffer holding one empty line and one cursor at the origin.
empty :: Buffer
empty = fromDocument (Doc.fromLines [])

-- | A buffer over the given lines (none means one empty line).
fromLines :: [B.ByteString] -> Buffer
fromLines = fromDocument . Doc.fromLines

-- | A buffer over a document: one primary cursor at @(0, 0)@, empty history.
fromDocument :: Document -> Buffer
fromDocument d = Buffer d [pointCursor True origin] [] []

-- | The current document.
document :: Buffer -> Document
document = bufDoc

-- | The cursors, in cursor order.
cursors :: Buffer -> [Cursor]
cursors = bufCursors

-- | Is there an edit to undo?
canUndo :: Buffer -> Bool
canUndo = not . null . bufUndo

-- | Is there an undone edit to redo?
canRedo :: Buffer -> Bool
canRedo = not . null . bufRedo

-- | Execute one command. 'Print' leaves the buffer unchanged: use 'render'
-- to obtain its output. The result is fully evaluated (cursors included),
-- so long command sequences build no thunks.
execute :: Command -> Buffer -> Buffer
execute cmd b = forceCursors (run cmd)
  where
    forceCursors r = foldr seq () (bufCursors r) `seq` r
    run = execute' b

execute' :: Buffer -> Command -> Buffer
execute' b cmd = case cmd of
  Insert t        -> edit (EditInsert t) b
  Delete          -> edit EditDelete b
  DeleteForward   -> edit EditDeleteForward b
  Move d sel      ->
    let moved = normalize (map (moveCursor d sel (bufDoc b)) (bufCursors b))
        keepGoal = d == MoveUp || d == MoveDown
    in b { bufCursors = if keepGoal then moved else resetGoals moved }
  Goto l c        ->
    setCursors [pointCursor True (Doc.clampPos (bufDoc b) (Pos l c))]
  AddCursor l c   ->
    setCursors (bufCursors b ++ [pointCursor False (Doc.clampPos (bufDoc b) (Pos l c))])
  ClearCursors    -> setCursors (filter curPrimary (bufCursors b))
  Undo            -> undo b
  Redo            -> redo b
  Print           -> b
  where
    setCursors cs = b { bufCursors = resetGoals (normalize cs) }

-- | Revert the most recent edit; does nothing if there is none.
undo :: Buffer -> Buffer
undo b = case bufUndo b of
  [] -> b { bufCursors = resetGoals (bufCursors b) }
  (e : rest) -> b
    { bufDoc = foldl' revert (bufDoc b) (reverse (entryReps e))
    , bufCursors = resetGoals (entryBefore e)
    , bufUndo = rest
    , bufRedo = e : bufRedo b
    }
  where
    revert d (Replacement s removed inserted) =
      Doc.replace s (advance s inserted) removed d

-- | Re-apply the most recently undone edit; does nothing if there is none.
redo :: Buffer -> Buffer
redo b = case bufRedo b of
  [] -> b { bufCursors = resetGoals (bufCursors b) }
  (e : rest) -> b
    { bufDoc = foldl' apply (bufDoc b) (entryReps e)
    , bufCursors = resetGoals (entryAfter e)
    , bufUndo = e : bufUndo b
    , bufRedo = rest
    }
  where
    apply d (Replacement s removed inserted) =
      Doc.replace s (advance s removed) inserted d

-- | Render a @print@: every line, one @cursor line col@ line per cursor
-- (heads, in cursor order), then @--@.
render :: Buffer -> Builder
render b =
  foldMap (\l -> byteString l <> char7 '\n') (Doc.toLines (bufDoc b))
    <> foldMap cursorLine (bufCursors b)
    <> byteString (B.pack "--\n")
  where
    cursorLine c = let Pos l col = curHead c in
      byteString (B.pack "cursor ") <> intDec l <> char7 ' ' <> intDec col <> char7 '\n'

------------------------------------------------------------------------
-- Editing

data EditKind = EditInsert !B.ByteString | EditDelete | EditDeleteForward

-- | The composed effect of the replacements so far: an original position
-- (the end of the last replaced range) and where it now lives. Every cursor
-- still to be processed lies at or after the original position, so it is
-- mapped in O(1).
data Shift = Shift !Pos !Pos

shiftPos :: Shift -> Pos -> Pos
shiftPos (Shift (Pos ol oc) (Pos nl nc)) (Pos l c)
  | l == ol   = Pos nl (nc + c - oc)
  | otherwise = Pos (l - ol + nl) c

data Acc = Acc !Document !Shift [Replacement] [Cursor]

edit :: EditKind -> Buffer -> Buffer
edit kind b
  | null reps = b { bufCursors = resetGoals (normalize newCursors) }
  | otherwise = b
      { bufDoc = doc'
      , bufCursors = after
      , bufUndo = Entry (bufCursors b) after (reverse reps) : bufUndo b
      , bufRedo = []
      }
  where
    Acc doc' _ reps revCursors =
      foldl' (editCursor kind) (Acc (bufDoc b) (Shift origin origin) [] [])
             (bufCursors b)
    newCursors = reverse revCursors
    after = resetGoals (normalize newCursors)

editCursor :: EditKind -> Acc -> Cursor -> Acc
editCursor kind (Acc doc shift reps out) c = Acc doc' shift' reps' (c' : out)
  where
    s0 = rangeStart c
    e0 = rangeEnd c
    s = shiftPos shift s0
    e = shiftPos shift e0
    sel = hasSelection c
    -- replaced range in the current document, the original-coordinates end
    -- of it, and the inserted text
    (rs, re, reOrig, text) = case kind of
      EditInsert t -> (s, e, e0, t)
      _ | sel -> (s, e, e0, B.empty)
      EditDelete
        | s == origin -> (s, s, e0, B.empty)
        | posCol s > 0 -> (Pos (posLine s) (posCol s - 1), s, e0, B.empty)
        | otherwise ->
            (Pos (posLine s - 1) (Doc.lineLength doc (posLine s - 1)), s, e0, B.empty)
      EditDeleteForward
        | s == Doc.endOfDocument doc -> (s, s, e0, B.empty)
        | posCol s < Doc.lineLength doc (posLine s) ->
            (s, Pos (posLine s) (posCol s + 1), Pos (posLine e0) (posCol e0 + 1), B.empty)
        | otherwise -> (s, Pos (posLine s + 1) 0, Pos (posLine e0 + 1) 0, B.empty)
    removed = B.copy (Doc.slice rs re doc)
    changed = not (B.null removed && B.null text)
    doc' | changed   = Doc.replace rs re text doc
         | otherwise = doc
    reps' | changed   = Replacement rs removed (B.copy text) : reps
          | otherwise = reps
    newHead = advance rs text
    shift' = Shift reOrig newHead
    c' = Cursor newHead Nothing (curPrimary c) (posCol newHead)
