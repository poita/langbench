-- | Parsing the @CREATE TABLE@ and @CREATE INDEX@ statements stored in
-- @sqlite_schema@. Only what the query engine needs is extracted: column
-- names, declared types, the rowid alias, and index column names.
module SqliteFile.DDL
  ( Token (..)
  , tokenize
  , TableDef (..)
  , ColumnDef (..)
  , parseCreateTable
  , IndexDef (..)
  , parseCreateIndex
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import SqliteFile.Value (lowerAscii)

-- | A lexical token of a DDL statement.
data Token
  = TWord ByteString -- ^ unquoted word (keyword or bare name)
  | TQuoted ByteString -- ^ quoted name, quotes removed and escapes resolved
  | TString ByteString -- ^ single-quoted string literal
  | TPunct Char -- ^ any other single character, e.g. @(@ @)@ @,@ @.@
  deriving (Eq, Show)

isWordChar :: Char -> Bool
isWordChar c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c == '_' || c == '$' || c >= '\x80'

-- | Split a statement into tokens, skipping whitespace and comments.
tokenize :: ByteString -> [Token]
tokenize s = case B.uncons s of
  Nothing -> []
  Just (c, r)
    | c `elem` " \t\n\r\f\v" -> tokenize r
    | c == '-', Just ('-', _) <- B.uncons r -> tokenize (B.dropWhile (/= '\n') r)
    | c == '/', Just ('*', r') <- B.uncons r -> tokenize (skipBlock r')
    | c == '"' || c == '`' -> let (t, rest) = quoted c r in TQuoted t : tokenize rest
    | c == '\'' -> let (t, rest) = quoted c r in TString t : tokenize rest
    | c == '[' -> let (t, rest) = B.break (== ']') r in TQuoted t : tokenize (B.drop 1 rest)
    | isWordChar c -> let (w, rest) = B.span isWordChar s in TWord w : tokenize rest
    | otherwise -> TPunct c : tokenize r
  where
    skipBlock x = case B.breakSubstring (B.pack "*/") x of
      (_, rest) -> B.drop 2 rest

-- Read up to the closing quote; a doubled quote is a literal quote.
quoted :: Char -> ByteString -> (ByteString, ByteString)
quoted q = go []
  where
    go acc x =
      let (chunk, rest) = B.break (== q) x
       in case B.uncons rest of
            Nothing -> (B.concat (reverse (chunk : acc)), B.empty)
            Just (_, rest')
              | Just (c2, rest'') <- B.uncons rest', c2 == q -> go (B.snoc chunk q : acc) rest''
              | otherwise -> (B.concat (reverse (chunk : acc)), rest')

kw :: String -> Token -> Bool
kw w (TWord t) = lowerAscii t == B.pack (map lower w)
  where lower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c
kw _ _ = False

anyKw :: [String] -> Token -> Bool
anyKw ws t = any (`kw` t) ws

tokenName :: Token -> Maybe ByteString
tokenName (TWord t) = Just t
tokenName (TQuoted t) = Just t
tokenName _ = Nothing

-- | A parsed column definition.
data ColumnDef = ColumnDef
  { cdName :: ByteString
  , cdType :: ByteString
  -- ^ declared type, tokens joined by single spaces (empty when absent)
  }
  deriving (Eq, Show)

-- | A parsed @CREATE TABLE@.
data TableDef = TableDef
  { tdName :: ByteString
  , tdColumns :: [ColumnDef]
  , tdRowidAlias :: Maybe Int
  -- ^ index of the column that aliases the rowid, if any
  }
  deriving (Eq, Show)

-- | Parse a @CREATE TABLE@ statement; 'Nothing' if it is not one.
parseCreateTable :: ByteString -> Maybe TableDef
parseCreateTable sql = do
  (_ : ts1) <- Just (tokenize sql)
  ts2 <- Just (dropOptional (anyKw ["TEMP", "TEMPORARY"]) ts1)
  (t : ts3) <- Just ts2
  if kw "TABLE" t then Just () else Nothing
  let ts4 = dropIfNotExists ts3
  (name, ts5) <- qualifiedName ts4
  (TPunct '(' : body) <- Just ts5
  let items = splitItems body
      isConstraint it = case it of
        (t0 : _) -> anyKw ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"] t0
        [] -> False
      colItems = filter (not . isConstraint) items
      tableItems = filter isConstraint items
  cols <- mapM parseColumn (filter (not . null) colItems)
  let tablePk = case [c' | it <- tableItems, Just c' <- [tablePrimaryKey it]] of
        (c' : _) -> Just c'
        [] -> Nothing
      aliasOf (i, (c', isInteger, colPk)) =
        if isInteger && (colPk || fmap lowerAscii tablePk == Just (lowerAscii (cdName c')))
          then Just i
          else Nothing
      alias = case [i | Just i <- map aliasOf (zip [0 ..] cols)] of
        (i : _) -> Just i
        [] -> Nothing
  Just (TableDef name [c' | (c', _, _) <- cols] alias)

dropOptional :: (Token -> Bool) -> [Token] -> [Token]
dropOptional p (t : ts) | p t = ts
dropOptional _ ts = ts

dropIfNotExists :: [Token] -> [Token]
dropIfNotExists (a : b : c : ts) | kw "IF" a && kw "NOT" b && kw "EXISTS" c = ts
dropIfNotExists ts = ts

-- [schema .] name
qualifiedName :: [Token] -> Maybe (ByteString, [Token])
qualifiedName (a : TPunct '.' : b : ts) | Just _ <- tokenName a, Just n <- tokenName b = Just (n, ts)
qualifiedName (a : ts) | Just n <- tokenName a = Just (n, ts)
qualifiedName _ = Nothing

-- Split the tokens following an opening parenthesis at depth-0 commas, up to
-- the matching close parenthesis.
splitItems :: [Token] -> [[Token]]
splitItems = go (0 :: Int) []
  where
    go _ cur [] = [reverse cur]
    go d cur (t : ts) = case t of
      TPunct '(' -> go (d + 1) (t : cur) ts
      TPunct ')' | d == 0 -> [reverse cur]
                 | otherwise -> go (d - 1) (t : cur) ts
      TPunct ',' | d == 0 -> reverse cur : go d [] ts
      _ -> go d (t : cur) ts

typeEnders :: [String]
typeEnders =
  [ "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT"
  , "COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT" ]

-- Returns the column, whether its type is exactly INTEGER, and whether it has
-- a column-level PRIMARY KEY (not followed by DESC).
parseColumn :: [Token] -> Maybe (ColumnDef, Bool, Bool)
parseColumn (n : rest) = do
  name <- tokenName n
  let (tyToks, cons) = break (anyKw typeEnders) rest
      tyText = B.unwords (map tokText tyToks)
      isInteger = case tyToks of
        [t] -> kw "INTEGER" t
        _ -> False
  Just (ColumnDef name tyText, isInteger, columnPrimaryKey cons)
parseColumn [] = Nothing

tokText :: Token -> ByteString
tokText (TWord t) = t
tokText (TQuoted t) = t
tokText (TString t) = t
tokText (TPunct c) = B.singleton c

-- Column-level "PRIMARY KEY" at paren depth 0, not followed by DESC.
columnPrimaryKey :: [Token] -> Bool
columnPrimaryKey = go (0 :: Int)
  where
    go _ [] = False
    go d (t : ts) = case t of
      TPunct '(' -> go (d + 1) ts
      TPunct ')' -> go (d - 1) ts
      _ | d == 0, kw "PRIMARY" t, (k : after) <- ts, kw "KEY" k ->
            case after of
              (x : _) | kw "DESC" x -> go d after
              _ -> True
        | otherwise -> go d ts

-- For a table constraint, the sole column of "PRIMARY KEY (col ...)".
tablePrimaryKey :: [Token] -> Maybe ByteString
tablePrimaryKey toks0 =
  let toks = case toks0 of
        (c : _ : rest) | kw "CONSTRAINT" c -> rest
        _ -> toks0
   in case toks of
        (p : k : TPunct '(' : rest) | kw "PRIMARY" p && kw "KEY" k ->
          case splitItems rest of
            [(c : _)] -> tokenName c
            _ -> Nothing
        _ -> Nothing

-- | A parsed @CREATE INDEX@.
data IndexDef = IndexDef
  { idName :: ByteString
  , idTable :: ByteString
  , idColumns :: [ByteString]
  }
  deriving (Eq, Show)

-- | Parse a @CREATE INDEX@ statement; 'Nothing' if it is not one.
parseCreateIndex :: ByteString -> Maybe IndexDef
parseCreateIndex sql = do
  (_ : ts1) <- Just (tokenize sql)
  let ts2 = dropOptional (kw "UNIQUE") ts1
  (t : ts3) <- Just ts2
  if kw "INDEX" t then Just () else Nothing
  let ts4 = dropIfNotExists ts3
  (name, ts5) <- qualifiedName ts4
  (o : ts6) <- Just ts5
  if kw "ON" o then Just () else Nothing
  (table, ts7) <- qualifiedName ts6
  (TPunct '(' : body) <- Just ts7
  cols <- mapM (\it -> case it of (c : _) -> tokenName c; [] -> Nothing) (splitItems body)
  Just (IndexDef name table cols)

