{-# LANGUAGE OverloadedStrings #-}
-- | The built-in filters.
module Template.Filters
  ( applyFilter
  ) where

import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.List (sortBy)
import Data.Ratio ((%))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

import Template.Error
import Template.Lexer (isWs)
import Template.Ops
import Template.Value

-- | Apply the named filter to an input value and evaluated arguments.
--
-- Except for @default@, an undefined input is reported before the argument
-- count is checked.
applyFilter :: Text -> Value -> [Value] -> Either ErrorKind Value
applyFilter name v args
  | name == "default" = case args of
      [] -> Right (dflt (VStr ""))
      [x] -> Right (dflt x)
      _ -> Left ErrType
  | isUndefined v = Left ErrUndefined
  | otherwise = case (name, args) of
      ("upper", []) -> VStr . T.map upperA <$> display v
      ("lower", []) -> VStr . T.map lowerA <$> display v
      ("trim", []) -> VStr . T.dropAround isWs <$> display v
      ("escape", []) -> VStr . escapeText <$> display v
      ("replace", [old, new]) -> do
        s <- display v
        o <- display old
        n <- display new
        Right (VStr (replaceAll o n s))
      ("length", []) -> case v of
        VStr t -> Right (VInt (fromIntegral (T.length t)))
        VList xs -> Right (VInt (fromIntegral (Seq.length xs)))
        VDict d -> Right (VInt (fromIntegral (dictSize d)))
        _ -> Left ErrType
      ("int", []) -> Right (VInt (toInt v))
      ("join", []) -> joinWith ""
      ("join", [sep]) -> display sep >>= joinWith
      ("first", []) -> (\xs -> maybe VUndefined id (Seq.lookup 0 xs)) <$> seqOf v
      ("last", []) -> (\xs -> maybe VUndefined id (Seq.lookup (Seq.length xs - 1) xs)) <$> seqOf v
      ("reverse", []) -> case v of
        VStr t -> Right (VStr (T.reverse t))
        _ -> VList . Seq.reverse <$> seqOf v
      ("sort", []) -> seqOf v >>= sortSeq
      _ -> Left ErrType
  where
    dflt x = if isUndefined v then x else v
    joinWith sep = do
      xs <- seqOf v
      parts <- mapM display (toList xs)
      Right (VStr (T.intercalate sep parts))

upperA, lowerA :: Char -> Char
upperA c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
lowerA c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

seqOf :: Value -> Either ErrorKind (Seq.Seq Value)
seqOf v = maybe (Left ErrType) Right (sequenceView v)

escapeText :: Text -> Text
escapeText = T.concatMap esc
  where
    esc c = case c of
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      '"' -> "&#34;"
      '\'' -> "&#39;"
      _ -> T.singleton c

-- Like Python's str.replace, including an empty pattern.
replaceAll :: Text -> Text -> Text -> Text
replaceAll old new s
  | T.null old = T.concat (new : concatMap (\c -> [T.singleton c, new]) (T.unpack s))
  | otherwise = T.replace old new s

sortSeq :: Seq.Seq Value -> Either ErrorKind Value
sortSeq xs
  | Seq.length xs < 2 = Right (VList xs)
  | Just ns <- mapM numOf items = Right (VList (Seq.fromList (map snd (sortBy (\a b -> numCompare (fst a) (fst b)) (zip ns items)))))
  | Just ks <- mapM strKey items = Right (VList (Seq.fromList (map snd (sortBy (\a b -> compare (fst a) (fst b)) (zip ks items)))))
  | otherwise = Left ErrType
  where
    items = toList xs
    numOf = asNumber
    strKey (VStr t) = Just (T.map lowerA t)
    strKey _ = Nothing

-- The @int@ filter.
toInt :: Value -> Integer
toInt v = case v of
  VInt n -> n
  VBool b -> if b then 1 else 0
  VFloat d -> truncate d
  VStr t -> parseIntString (T.dropAround isWs t)
  _ -> 0

parseIntString :: Text -> Integer
parseIntString t0
  | not (T.null ip) && T.null r1 = sign * read (T.unpack ip)
  | otherwise = maybe 0 (\x -> sign * x) decimal
  where
    (sign, body) = case T.uncons t0 of
      Just ('+', r) -> (1, r)
      Just ('-', r) -> (-1, r)
      _ -> (1, t0)
    (ip, r1) = T.span isDigit body
    -- mantissa digits, number of fraction digits, and the remaining text
    mantissa :: Maybe (Text, Int, Text)
    mantissa = case T.uncons r1 of
      Just ('.', r) ->
        let (fp, r2) = T.span isDigit r
        in if T.null ip && T.null fp then Nothing else Just (ip <> fp, T.length fp, r2)
      _ -> if T.null ip then Nothing else Just (ip, 0, r1)
    exponentPart :: Text -> Maybe Integer
    exponentPart r = case T.uncons r of
      Nothing -> Just 0
      Just (e, r') | e == 'e' || e == 'E' ->
        let (esign, r'') = case T.uncons r' of
              Just ('+', x) -> (1, x)
              Just ('-', x) -> (-1, x)
              _ -> (1, r')
            (eds, rest) = T.span isDigit r''
        in if T.null eds || not (T.null rest) then Nothing
           else Just (esign * min 1000 (read (T.unpack eds)))
      _ -> Nothing
    decimal :: Maybe Integer
    decimal = do
      (digits, fracLen, r2) <- mantissa
      ex <- exponentPart r2
      let m = read (T.unpack digits) :: Integer
          scale = ex - fromIntegral fracLen
          q = if scale >= 0 then fromInteger (m * 10 ^ scale) else m % (10 ^ negate scale)
      Just (truncate (fromRational q :: Double))
