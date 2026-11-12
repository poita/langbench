-- |
-- Module      : Spreadsheet.Sheet
-- Description : The spreadsheet: contents, stored values and incremental recalculation.
--
-- A 'Sheet' is an immutable (persistent) value.  'setCell' and 'clearCell'
-- return a new sheet in which every formula cell's stored value is again
-- consistent with the sheet's contents.
--
-- /How recalculation works./  The sheet keeps, for every cell, the set of
-- cells its formula reads and (in the reverse direction) the set of cells
-- that read it.  After an edit, the /affected set/ — the edited cell plus all
-- cells that transitively read it — is found by following reverse edges.
-- Tarjan's algorithm over the subgraph induced by the affected set yields its
-- strongly connected components dependencies-first; a cyclic component is
-- given @#CYCLE!@ and every other cell is evaluated as soon as its component
-- is emitted, reading the already-updated stored values of what it depends
-- on.  Only affected cells are touched, so the cost of an edit is independent
-- of the size of the rest of the sheet.
module Spreadsheet.Sheet
  ( Sheet
  , empty
  , setCell
  , setContent
  , clearCell
  , lookupValue
  , lookupContent
  , toList
  , size
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Text (Text)

import Spreadsheet.Eval (dependencies, evaluate)
import Spreadsheet.Graph (Component (..), components)
import Spreadsheet.Parser (ParseError, parseContent)
import Spreadsheet.Types

data Cell = Cell
  { cellContent :: !Content
  , cellValue :: !Value
  , cellDeps :: !IntSet
  }

-- | A spreadsheet.
data Sheet = Sheet
  { sheetCells :: !(IntMap Cell)
    -- ^ non-empty cells, keyed by 'refKey' (so in row-major order)
  , sheetDependents :: !(IntMap IntSet)
    -- ^ reverse edges: for each cell, the formula cells that read it
  }

-- | A sheet with no cells.
empty :: Sheet
empty = Sheet IntMap.empty IntMap.empty

-- | Number of non-empty cells.
size :: Sheet -> Int
size = IntMap.size . sheetCells

-- | The current value of a cell; 'Nothing' if it is empty.  O(log C).
lookupValue :: CellRef -> Sheet -> Maybe Value
lookupValue ref s = cellValue <$> IntMap.lookup (refKey ref) (sheetCells s)

-- | What was last stored in a cell; 'Nothing' if it is empty.
lookupContent :: CellRef -> Sheet -> Maybe Content
lookupContent ref s = cellContent <$> IntMap.lookup (refKey ref) (sheetCells s)

-- | All non-empty cells with their values, in row-major order.
toList :: Sheet -> [(CellRef, Value)]
toList s = [(keyRef k, cellValue c) | (k, c) <- IntMap.toAscList (sheetCells s)]

-- | Replace a cell's content from its source text (@\"=A1+1\"@, @\"\\\"hi\\\"\"@,
-- @\"4.5\"@) and recalculate.
setCell :: CellRef -> Text -> Sheet -> Either ParseError Sheet
setCell ref src s = (\c -> setContent ref c s) <$> parseContent src

-- | Replace a cell's content and recalculate the affected cells.
setContent :: CellRef -> Content -> Sheet -> Sheet
setContent ref content s = recalculate k (Sheet cells' dependents')
  where
    k = refKey ref
    newDeps = case content of
      CFormula e -> dependencies e
      _ -> IntSet.empty
    initial = case content of
      CNumber d -> VNumber d
      CText t -> VText t
      CFormula _ -> VNumber 0 -- replaced by 'recalculate'
    cells' = IntMap.insert k (Cell content initial newDeps) (sheetCells s)
    dependents' = relink k (oldDeps k s) newDeps (sheetDependents s)

-- | Make a cell empty and recalculate the affected cells.
clearCell :: CellRef -> Sheet -> Sheet
clearCell ref s
  | IntMap.member k (sheetCells s) =
      recalculate k (Sheet (IntMap.delete k (sheetCells s)) (relink k (oldDeps k s) IntSet.empty (sheetDependents s)))
  | otherwise = s
  where
    k = refKey ref

oldDeps :: Int -> Sheet -> IntSet
oldDeps k s = maybe IntSet.empty cellDeps (IntMap.lookup k (sheetCells s))

-- | Move cell @k@ from the reverse-edge sets of its old dependencies to
-- those of its new ones.  Only the symmetric difference is touched.
relink :: Int -> IntSet -> IntSet -> IntMap IntSet -> IntMap IntSet
relink k old new m0 = added
  where
    removed = IntSet.foldl' (\m d -> IntMap.update (nonEmpty . IntSet.delete k) d m) m0 (old `IntSet.difference` new)
    added = IntSet.foldl' (\m d -> IntMap.insertWith IntSet.union d (IntSet.singleton k) m) removed (new `IntSet.difference` old)
    nonEmpty x = if IntSet.null x then Nothing else Just x

-- | Bring every cell affected by an edit of @k@ up to date.
recalculate :: Int -> Sheet -> Sheet
recalculate k sheet = foldl' step sheet (components succs (IntSet.toList affected))
  where
    dependents = sheetDependents sheet
    affected = reach dependents k
    -- Edges run from a cell to the affected cells it reads.
    succs n = case IntMap.lookup n (sheetCells sheet) of
      Nothing -> []
      Just c -> filter (`IntSet.member` affected) (IntSet.toList (cellDeps c))

    step sh (Acyclic n) = case IntMap.lookup n (sheetCells sh) of
      Just c@Cell {cellContent = CFormula e} ->
        let v = evaluate (\key -> cellValue <$> IntMap.lookup key (sheetCells sh)) e
         in sh {sheetCells = IntMap.insert n c {cellValue = v} (sheetCells sh)}
      _ -> sh
    step sh (Cyclic ns) =
      sh {sheetCells = foldl' (\m n -> IntMap.adjust (\c -> c {cellValue = VError ErrCycle}) n m) (sheetCells sh) ns}

-- | The cell @k@ and everything that transitively reads it.
reach :: IntMap IntSet -> Int -> IntSet
reach dependents k0 = go (IntSet.singleton k0) [k0]
  where
    go seen [] = seen
    go seen (x : work) =
      let new = maybe IntSet.empty (`IntSet.difference` seen) (IntMap.lookup x dependents)
       in go (IntSet.union seen new) (IntSet.toList new ++ work)
