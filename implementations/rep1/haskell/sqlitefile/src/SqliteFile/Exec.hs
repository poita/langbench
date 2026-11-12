-- | Executing parsed commands against a database.
module SqliteFile.Exec
  ( Row
  , execute
  , renderRows
  ) where

import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder, byteString, char7, word8)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List (intersperse, nub, sort, sortBy)
import SqliteFile.BTree
import SqliteFile.Catalog
import SqliteFile.Error (queryError)
import SqliteFile.Format (formatReal)
import SqliteFile.Pager (Database)
import SqliteFile.Query
import SqliteFile.Record (decodeRecord)
import SqliteFile.Value

-- | One output row: a list of values.
type Row = [Value]

-- | Execute a command. Name-resolution problems are reported eagerly as a
-- 'SqliteFile.Error.QueryError' exception when the result is first demanded
-- (see 'SqliteFile.runQuery'); rows are produced lazily, so corrupt data may
-- also surface as a 'SqliteFile.Error.CorruptDatabase' exception while the
-- rows are consumed.
execute :: Database -> Catalog -> Command -> [Row]
execute db cat cmd = case cmd of
  Tables ->
    [ [VText n]
    | n <- sort [srName r | r <- catRows cat, srType r == B.pack "table", not (isInternal (srName r))]
    ]
  SchemaOf name ->
    [ [VText (sql <> B.pack ";")]
    | r <- catRows cat
    , lowerAscii (srTblName r) == lowerAscii name
    , Just sql <- [srSql r]
    ]
  Count name -> case lookupTable cat name of
    Nothing -> queryError ("no such table: " ++ B.unpack name)
    Just t -> [[VInt (fromIntegral (tableCount db (tableRoot t)))]]
  SelectCmd sel -> select db cat sel
  IndexLookup name lit -> indexQuery db cat name lit
  where
    isInternal n = B.pack "sqlite_" `B.isPrefixOf` lowerAscii n

-- Where a column's value comes from.
data Source = FromRowid | FromColumn Int

sourceTag :: Source -> ()
sourceTag FromRowid = ()
sourceTag (FromColumn _) = ()

-- Resolve a column name: a real column wins over the rowid pseudo-column.
resolve :: Table -> ByteString -> (Source, Affinity)
resolve t name =
  case [(i, c) | (i, c) <- zip [0 ..] (tableColumns t), lowerAscii (colName c) == lowerAscii name] of
    ((i, c) : _) -> (FromColumn i, colAffinity c)
    [] | lowerAscii name == B.pack "rowid" -> (FromRowid, AffInteger)
       | otherwise -> queryError ("no such column: " ++ B.unpack name)

fetch :: Source -> Int64 -> [Value] -> Value
fetch FromRowid rowid _ = VInt rowid
fetch (FromColumn i) _ vals = vals !! i

getTable :: Catalog -> ByteString -> Table
getTable cat name = case lookupTable cat name of
  Just t -> t
  Nothing -> queryError ("no such table: " ++ B.unpack name)

select :: Database -> Catalog -> Select -> [Row]
select db cat sel =
  let t = getTable cat (selTable sel)
      width = length (tableColumns t)
      outputs = case selProjection sel of
        Star -> [FromColumn i | i <- [0 .. width - 1]]
        Columns cs -> [fst (resolve t c) | c <- cs]
      conds = [ (src, op, applyAffinity aff lit)
              | Cond c op lit <- selWhere sel
              , let (src, aff) = resolve t c ]
      order = fmap (\(c, d) -> (fst (resolve t c), d)) (selOrderBy sel)
      matches rowid vals = and [holds op (fetch src rowid vals) lit | (src, op, lit) <- conds]
      scanned =
        [ (rowid, vals)
        | (rowid, payload) <- tableRows db (tableRoot t)
        , let vals = columnValues t rowid payload
        , matches rowid vals
        ]
      project (rowid, vals) = [fetch s rowid vals | s <- outputs]
      limited xs = maybe xs (\n -> take (fromIntegral (min n (fromIntegral (maxBound :: Int)))) xs) (selLimit sel)
      -- Resolve every name up front so a bad query fails even on an empty table.
      resolved = foldr seq () [sourceTag src | (src, _, _) <- conds]
      resolvedOut = foldr (\o acc -> sourceTag o `seq` acc) () outputs
      resolvedOrder = maybe () (sourceTag . fst) order
   in resolved `seq` resolvedOut `seq` resolvedOrder `seq` case order of
        Nothing -> map project (limited scanned)
        Just (src, dir) ->
          let keyed = [(fetch src rowid vals, r) | r@(rowid, vals) <- scanned]
              cmpKeys (a, _) (b, _) = case dir of
                Asc -> compareValues a b
                Desc -> compareValues b a
           in map (project . snd) (limited (sortBy cmpKeys keyed))

-- Does "value op literal" hold? Comparisons with NULL are false, except IS.
holds :: Op -> Value -> Value -> Bool
holds op v lit = case op of
  OpEq -> notNull && compareValues v lit == EQ
  OpNe -> notNull && compareValues v lit /= EQ
  OpLt -> notNull && compareValues v lit == LT
  OpLe -> notNull && compareValues v lit /= GT
  OpGt -> notNull && compareValues v lit == GT
  OpGe -> notNull && compareValues v lit /= LT
  OpIs -> isEq
  OpIsNot -> not isEq
  where
    notNull = v /= VNull && lit /= VNull
    isEq = compareValues v lit == EQ

indexQuery :: Database -> Catalog -> ByteString -> Value -> [Row]
indexQuery db cat name lit =
  case lookupIndex cat name of
    Nothing -> queryError ("no such index: " ++ B.unpack name)
    Just ix -> case indexColumns ix of
      [col] ->
        let t = getTable cat (indexTable ix)
            aff = snd (resolve t col)
            key = applyAffinity aff lit
            cmp payload = case decodeRecord payload of
              (v : _) -> compareValues v key
              [] -> GT
            rowidOf payload = case reverse (decodeRecord payload) of
              (VInt r : _) -> [r]
              _ -> []
         in if key == VNull
              then []
              else
                [ columnValues t rowid payload
                | rowid <- nub (sort (concatMap rowidOf (indexLookup db (indexRoot ix) cmp)))
                , Just payload <- [tableLookup db (tableRoot t) rowid]
                ]
      _ -> queryError "index must have exactly one column"

-- | Render rows as the spec's output text: values joined by tabs, one row
-- per line.
renderRows :: [Row] -> Builder
renderRows = foldMap (\r -> mconcat (intersperse (char7 '\t') (map renderValue r)) <> char7 '\n')

renderValue :: Value -> Builder
renderValue v = case v of
  VNull -> byteString (B.pack "NULL")
  VInt i -> byteString (B.pack (show i))
  VReal d -> byteString (formatReal d)
  VText t -> byteString t
  VBlob b -> foldMap hex (BS.unpack b)
  where
    hex w = digit (w `shiftR` 4) <> digit (w .&. 15)
    digit n = word8 (if n < 10 then 48 + n else 55 + n)
