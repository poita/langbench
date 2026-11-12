-- | The query language: the five commands of the specification and a parser
-- for them. Parsing is a single left-to-right pass over the line.
module SqliteFile.Query
  ( Command (..)
  , Select (..)
  , Projection (..)
  , Cond (..)
  , Op (..)
  , Direction (..)
  , parseCommand
  ) where

import Control.Applicative (Alternative (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit)
import Data.Int (Int64)
import SqliteFile.Value (Value (..), lowerAscii, scanNumeric)

-- | A parsed query line.
data Command
  = Tables
  | SchemaOf ByteString
  | Count ByteString
  | SelectCmd Select
  | IndexLookup ByteString Value
  deriving (Eq, Show)

-- | A @SELECT@ statement.
data Select = Select
  { selProjection :: Projection
  , selTable :: ByteString
  , selWhere :: [Cond]
  , selOrderBy :: Maybe (ByteString, Direction)
  , selLimit :: Maybe Int64
  }
  deriving (Eq, Show)

data Projection = Star | Columns [ByteString]
  deriving (Eq, Show)

-- | @column op literal@.
data Cond = Cond ByteString Op Value
  deriving (Eq, Show)

data Op = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe | OpIs | OpIsNot
  deriving (Eq, Show)

data Direction = Asc | Desc
  deriving (Eq, Show)

-- A tiny backtracking parser over the remaining input.
newtype P a = P {runP :: ByteString -> Maybe (a, ByteString)}

instance Functor P where
  fmap f (P g) = P $ \s -> fmap (\(a, r) -> (f a, r)) (g s)

instance Applicative P where
  pure a = P $ \s -> Just (a, s)
  P f <*> P g = P $ \s -> case f s of
    Nothing -> Nothing
    Just (h, r) -> case g r of
      Nothing -> Nothing
      Just (a, r') -> Just (h a, r')

instance Monad P where
  P g >>= f = P $ \s -> case g s of
    Nothing -> Nothing
    Just (a, r) -> runP (f a) r

instance Alternative P where
  empty = P (const Nothing)
  P f <|> P g = P $ \s -> maybe (g s) Just (f s)

isWordChar :: Char -> Bool
isWordChar c = isDigit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'

isBlank :: Char -> Bool
isBlank c = c == ' ' || c == '\t'

ws :: P ()
ws = P $ \s -> Just ((), B.dropWhile isBlank s)

-- A single character, then optional blanks.
sym :: Char -> P ()
sym c = P $ \s -> case B.uncons s of
  Just (x, r) | x == c -> Just ((), B.dropWhile isBlank r)
  _ -> Nothing

-- A whole word (maximal run of word characters), then optional blanks.
word :: P ByteString
word = P $ \s ->
  let (w, r) = B.span isWordChar s
   in if B.null w then Nothing else Just (w, B.dropWhile isBlank r)

-- A specific keyword, matched case-insensitively as a whole word.
keyword :: String -> P ()
keyword k = do
  w <- word
  if lowerAscii w == B.pack (map lowerC k) then pure () else empty
  where lowerC c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- A bare identifier: [A-Za-z_][A-Za-z0-9_]*
identifier :: P ByteString
identifier = do
  w <- word
  case B.uncons w of
    Just (c, _) | not (isDigit c) -> pure w
    _ -> empty

eof :: P ()
eof = P $ \s -> if B.null s then Just ((), s) else Nothing

optionalP :: P a -> P (Maybe a)
optionalP p = (Just <$> p) <|> pure Nothing

-- | Parse one query line. 'Nothing' means the line is malformed.
parseCommand :: ByteString -> Maybe Command
parseCommand line = fst <$> runP (dotCommand <|> (ws *> sqlCommand)) line
  where
    dotCommand = P $ \s ->
      if B.pack ".tables" == s
        then Just (Tables, B.empty)
        else case B.stripPrefix (B.pack ".schema") s of
          Just r | Just (' ', arg) <- B.uncons r, validIdent arg -> Just (SchemaOf arg, B.empty)
          _ -> Nothing
    validIdent a = case B.uncons a of
      Just (c, _) -> not (isDigit c) && B.all isWordChar a
      Nothing -> False

sqlCommand :: P Command
sqlCommand = selectCmd <|> countCmd <|> indexCmd
  where
    countCmd = do
      keyword "COUNT"
      t <- identifier
      eof
      pure (Count t)
    indexCmd = do
      keyword "INDEX"
      n <- identifier
      v <- literal
      eof
      pure (IndexLookup n v)

selectCmd :: P Command
selectCmd = do
  keyword "SELECT"
  proj <- (Star <$ sym '*') <|> (Columns <$> columnList)
  keyword "FROM"
  table <- identifier
  conds <- (keyword "WHERE" *> condList) <|> pure []
  order <- optionalP orderBy
  limit <- optionalP (keyword "LIMIT" *> limitValue)
  eof
  pure (SelectCmd (Select proj table conds order limit))

columnList :: P [ByteString]
columnList = do
  c <- identifier
  rest <- many (sym ',' *> identifier)
  pure (c : rest)

condList :: P [Cond]
condList = do
  c <- cond
  rest <- many (keyword "AND" *> cond)
  pure (c : rest)

cond :: P Cond
cond = do
  col <- identifier
  op <- operator
  Cond col op <$> literal

operator :: P Op
operator =
  (OpLe <$ sym2 '<' '=')
    <|> (OpGe <$ sym2 '>' '=')
    <|> (OpNe <$ sym2 '!' '=')
    <|> (OpLt <$ sym '<')
    <|> (OpGt <$ sym '>')
    <|> (OpEq <$ sym '=')
    <|> (OpIsNot <$ (keyword "IS" *> keyword "NOT"))
    <|> (OpIs <$ keyword "IS")
  where
    -- both characters must be adjacent
    sym2 a b = P $ \s -> case B.unpack (B.take 2 s) of
      [x, y] | x == a && y == b -> Just ((), B.dropWhile isBlank (B.drop 2 s))
      _ -> Nothing

orderBy :: P (ByteString, Direction)
orderBy = do
  keyword "ORDER"
  keyword "BY"
  c <- identifier
  d <- (Asc <$ keyword "ASC") <|> (Desc <$ keyword "DESC") <|> pure Asc
  pure (c, d)

limitValue :: P Int64
limitValue = P $ \s ->
  let (ds, r) = B.span isDigit s
   in if B.null ds || startsWord r
        then Nothing
        else
          let n = B.foldl' (\a c -> min (toInteger (maxBound :: Int64)) (a * 10 + toInteger (fromEnum c - 48))) 0 ds
           in Just (fromInteger n, B.dropWhile isBlank r)

startsWord :: ByteString -> Bool
startsWord r = case B.uncons r of
  Just (c, _) -> isWordChar c
  Nothing -> False

-- | A literal: numeral, string, blob or NULL. Followed by optional blanks.
literal :: P Value
literal = P $ \s -> case runP lit s of
  Just (v, r) -> Just (v, B.dropWhile isBlank r)
  Nothing -> Nothing
  where
    lit = P $ \s -> case B.uncons s of
      Just ('\'', r) -> (\(t, r') -> (VText t, r')) <$> quotedString r
      Just (c, r)
        | (c == 'x' || c == 'X'), Just ('\'', r') <- B.uncons r -> blob r'
        | isDigit c || c == '+' || c == '-' -> case scanNumeric False s of
            Just (v, rest) | not (startsWord rest) -> Just (v, rest)
            _ -> Nothing
      _ -> do
        let (w, r) = B.span isWordChar s
        if lowerAscii w == B.pack "null" then Just (VNull, r) else Nothing
    quotedString = go []
      where
        go acc x =
          let (chunk, rest) = B.break (== '\'') x
           in case B.uncons rest of
                Nothing -> Nothing
                Just (_, r)
                  | Just ('\'', r') <- B.uncons r -> go (B.snoc chunk '\'' : acc) r'
                  | otherwise -> Just (B.concat (reverse (chunk : acc)), r)
    blob r =
      let (hex, rest) = B.break (== '\'') r
       in case B.uncons rest of
            Just (_, r')
              | even (B.length hex), B.all isHex hex -> Just (VBlob (unhex hex), r')
            _ -> Nothing
    isHex c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    unhex h = B.pack (pairs (B.unpack h))
    pairs (a : b : xs) = toEnum (hexVal a * 16 + hexVal b) : pairs xs
    pairs _ = []
    hexVal c
      | isDigit c = fromEnum c - 48
      | c >= 'a' = fromEnum c - 87
      | otherwise = fromEnum c - 55
