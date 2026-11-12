{-# LANGUAGE OverloadedStrings #-}

-- | Pure operators, comparisons and filters of the template language.
module Sitegen.Template.Ops
  ( R
  , truthy
  , toText
  , sequenceView
  , valuesEqual
  , binaryOp
  , negateValue
  , compareOp
  , getItem
  , applyFilter
  , toInteger'
  ) where

import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Template.Lexer (isTemplateSpace)
import Sitegen.Template.Syntax (BinOp (..), CmpOp (..), ErrorKind (..))
import Sitegen.Template.Value

-- | A result that may be a template error.
type R = Either ErrorKind

data Num' = NI Integer | NF Double

toNum :: Value -> Maybe Num'
toNum v = case v of
  VInt i -> Just (NI i)
  VBool b -> Just (NI (if b then 1 else 0))
  VFloat d -> Just (NF d)
  _ -> Nothing

-- | Integers and booleans as integers.
toInteger' :: Value -> Maybe Integer
toInteger' v = case v of
  VInt i -> Just i
  VBool b -> Just (if b then 1 else 0)
  _ -> Nothing

toDouble :: Num' -> Double
toDouble (NI i) = fromInteger i
toDouble (NF d) = d

checkDefined :: Value -> R ()
checkDefined VUndefined = Left UndefinedError
checkDefined _ = Right ()

-- | Truthiness. Testing the undefined value is an error.
truthy :: Value -> R Bool
truthy v = case v of
  VUndefined -> Left UndefinedError
  VNone -> Right False
  VBool b -> Right b
  VInt i -> Right (i /= 0)
  VFloat d -> Right (d /= 0)
  VString s -> Right (not (T.null s))
  VList xs -> Right (not (Seq.null xs))
  VDict d -> Right (dictSize d /= 0)
  _ -> Right True

-- | The string form of a value, as printed.
toText :: Value -> R Text
toText v = case displayValue v of
  Just t -> Right t
  Nothing -> Left (if isDefined v then TypeError else UndefinedError)

-- | The sequence view: list elements, dict keys or string characters.
sequenceView :: Value -> R [Value]
sequenceView v = case v of
  VList xs -> Right (toList xs)
  VDict d -> Right (map VString (dictKeys d))
  VString s -> Right (map (VString . T.singleton) (T.unpack s))
  VUndefined -> Left UndefinedError
  _ -> Left TypeError

-- | Template equality: numbers by value, containers structurally.
valuesEqual :: Value -> Value -> Bool
valuesEqual a b = case (a, b) of
  (VNone, VNone) -> True
  (VString x, VString y) -> x == y
  (VList xs, VList ys) -> Seq.length xs == Seq.length ys && and (zipWith valuesEqual (toList xs) (toList ys))
  (VDict x, VDict y) ->
    dictSize x == dictSize y
      && all (\(k, v) -> maybe False (valuesEqual v) (dictLookup k y)) (dictToList x)
  _ -> case (toNum a, toNum b) of
    (Just (NI x), Just (NI y)) -> x == y
    (Just x, Just y) -> toDouble x == toDouble y
    _ -> False

numCompare :: Num' -> Num' -> Ordering
numCompare (NI x) (NI y) = compare x y
numCompare x y = compare (toDouble x) (toDouble y)

-- | Comparison operators. Both operands must be defined.
compareOp :: CmpOp -> Value -> Value -> R Bool
compareOp op a b = do
  checkDefined a
  checkDefined b
  case op of
    Eq -> Right (valuesEqual a b)
    Ne -> Right (not (valuesEqual a b))
    Lt -> ordering (== LT)
    Le -> ordering (/= GT)
    Gt -> ordering (== GT)
    Ge -> ordering (/= LT)
    In -> membership
    NotIn -> not <$> membership
  where
    ordering f = case (toNum a, toNum b, a, b) of
      (Just x, Just y, _, _) -> Right (f (numCompare x y))
      (_, _, VString x, VString y) -> Right (f (compare x y))
      _ -> Left TypeError
    membership = case b of
      VString hay -> case a of
        VString needle -> Right (needle `T.isInfixOf` hay)
        _ -> Left TypeError
      VDict d -> Right $ case a of
        VString k -> maybe False (const True) (dictLookup k d)
        _ -> False
      VList xs -> Right (any (valuesEqual a) (toList xs))
      _ -> Left TypeError

-- | Unary minus.
negateValue :: Value -> R Value
negateValue v = do
  checkDefined v
  case toNum v of
    Just (NI i) -> Right (VInt (negate i))
    Just (NF d) -> Right (VFloat (negate d))
    Nothing -> Left TypeError

-- | Binary arithmetic and string concatenation.
binaryOp :: BinOp -> Value -> Value -> R Value
binaryOp op a b = do
  checkDefined a
  checkDefined b
  case op of
    Add -> case (toNum a, toNum b, a, b) of
      (Just (NI x), Just (NI y), _, _) -> Right (VInt (x + y))
      (Just x, Just y, _, _) -> Right (VFloat (toDouble x + toDouble y))
      (_, _, VString x, VString y) -> Right (VString (x <> y))
      (_, _, VList x, VList y) -> Right (VList (x Seq.>< y))
      _ -> Left TypeError
    Sub -> numeric (\x y -> x - y) (-)
    Mul -> case (toNum a, toNum b) of
      (Just (NI x), Just (NI y)) -> Right (VInt (x * y))
      (Just x, Just y) -> Right (VFloat (toDouble x * toDouble y))
      _ -> case (a, toInteger' b, toInteger' a, b) of
        (VString s, Just n, _, _) -> Right (VString (repeatText s n))
        (_, _, Just n, VString s) -> Right (VString (repeatText s n))
        _ -> Left TypeError
    Div -> case (toNum a, toNum b) of
      (Just x, Just y)
        | toDouble y == 0 -> Left TypeError
        | otherwise -> Right (VFloat (toDouble x / toDouble y))
      _ -> Left TypeError
    FloorDiv -> case (toNum a, toNum b) of
      (Just (NI x), Just (NI y))
        | y == 0 -> Left TypeError
        | otherwise -> Right (VInt (x `div` y))
      (Just x, Just y)
        | toDouble y == 0 -> Left TypeError
        | otherwise -> Right (VFloat (fromInteger (floor (toDouble x / toDouble y))))
      _ -> Left TypeError
    Mod -> case (toNum a, toNum b) of
      (Just (NI x), Just (NI y))
        | y == 0 -> Left TypeError
        | otherwise -> Right (VInt (x `mod` y))
      (Just x, Just y)
        | toDouble y == 0 -> Left TypeError
        | otherwise ->
            let xd = toDouble x
                yd = toDouble y
             in Right (VFloat (xd - yd * fromInteger (floor (xd / yd))))
      _ -> Left TypeError
    Pow -> case (toNum a, toNum b) of
      (Just (NI x), Just (NI y))
        | y >= 0 -> Right (VInt (x ^ y))
        | x == 0 -> Left TypeError
        | otherwise -> Right (VFloat (fromInteger x ** fromInteger y))
      (Just x, Just y) -> Right (VFloat (toDouble x ** toDouble y))
      _ -> Left TypeError
    Concat -> do
      x <- toText a
      y <- toText b
      Right (VString (x <> y))
  where
    numeric fi fd = case (toNum a, toNum b) of
      (Just (NI x), Just (NI y)) -> Right (VInt (fi x y))
      (Just x, Just y) -> Right (VFloat (fd (toDouble x) (toDouble y)))
      _ -> Left TypeError
    repeatText s n = if n <= 0 then T.empty else T.replicate (fromInteger n) s

-- | Attribute and subscript access: @a.k@ and @a[k]@.
getItem :: Value -> Value -> R Value
getItem a k = do
  checkDefined a
  checkDefined k
  Right $ case (a, k) of
    (VDict d, VString key) -> maybe VUndefined id (dictLookup key d)
    (VList xs, _) | Just i <- toInteger' k -> maybe VUndefined id (index (Seq.length xs) i (Seq.lookup . fromInteger) xs)
    (VString s, _) | Just i <- toInteger' k ->
      maybe VUndefined (VString . T.singleton) (index (T.length s) i (\j t -> if j < T.length t then Just (T.index t j) else Nothing) s)
    _ -> VUndefined
  where
    index len i look container =
      let j = if i < 0 then i + toInteger len else i
       in if j < 0 || j >= toInteger len then Nothing else look (fromInteger j) container

-- ---------------------------------------------------------------------------
-- Filters

-- | Apply a built-in filter to an input and already-evaluated arguments.
applyFilter :: Text -> Value -> [Value] -> R Value
applyFilter name input args
  | name == "default" = case args of
      [] -> Right (def "")
      [x] -> Right (def' x)
      _ -> Left TypeError
  | otherwise = do
      checkDefined input
      case (name, args) of
        ("upper", []) -> VString . T.map upperA <$> toText input
        ("lower", []) -> VString . T.map lowerA <$> toText input
        ("trim", []) -> VString . T.dropAround isTemplateSpace <$> toText input
        ("escape", []) -> VString . T.concatMap escapeChar <$> toText input
        ("replace", [o, n]) -> do
          s <- toText input
          old <- toText o
          new <- toText n
          Right (VString (replaceAll old new s))
        ("length", []) -> case input of
          VString s -> Right (VInt (toInteger (T.length s)))
          VList xs -> Right (VInt (toInteger (Seq.length xs)))
          VDict d -> Right (VInt (toInteger (dictSize d)))
          _ -> Left TypeError
        ("int", []) -> Right (VInt (toInt input))
        ("join", []) -> joinWith ""
        ("join", [sep]) -> toText sep >>= joinWith
        ("first", []) -> do
          xs <- sequenceView input
          Right (case xs of [] -> VUndefined; (x : _) -> x)
        ("last", []) -> do
          xs <- sequenceView input
          Right (if null xs then VUndefined else last xs)
        ("reverse", []) -> case input of
          VString s -> Right (VString (T.reverse s))
          _ -> mkList . reverse <$> sequenceView input
        ("sort", []) -> sequenceView input >>= sortValues
        _ -> Left TypeError
  where
    def d = if isDefined input then input else VString d
    def' x = if isDefined input then input else x
    joinWith sep = do
      xs <- sequenceView input
      parts <- mapM toText xs
      Right (VString (T.intercalate sep parts))
    upperA c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
    lowerA c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

escapeChar :: Char -> Text
escapeChar c = case c of
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&#34;"
  '\'' -> "&#39;"
  _ -> T.singleton c

replaceAll :: Text -> Text -> Text -> Text
replaceAll old new s
  | T.null old = new <> T.concatMap (\c -> T.singleton c <> new) s
  | otherwise = T.replace old new s

sortValues :: [Value] -> R Value
sortValues xs
  | all isNum xs = Right (mkList (sortBy (\a b -> cmpNum a b) xs))
  | all isStr xs = Right (mkList (sortBy (comparing key) xs))
  | otherwise = Left TypeError
  where
    isNum v = maybe False (const True) (toNum v)
    isStr v = case v of VString _ -> True; _ -> False
    cmpNum a b = case (toNum a, toNum b) of
      (Just x, Just y) -> numCompare x y
      _ -> EQ
    key v = case v of
      VString s -> T.map (\c -> if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c) s
      _ -> T.empty

-- | The @int@ filter.
toInt :: Value -> Integer
toInt v = case v of
  VInt i -> i
  VBool b -> if b then 1 else 0
  VFloat d -> truncate d
  VString s ->
    let t = T.dropAround isTemplateSpace s
     in case parseIntText t of
          Just i -> i
          Nothing -> maybe 0 truncate (parseDecimal t)
  _ -> 0

parseIntText :: Text -> Maybe Integer
parseIntText t = case T.uncons t of
  Just ('-', r) | allDigits r -> Just (negate (readInt r))
  Just ('+', r) | allDigits r -> Just (readInt r)
  _ | allDigits t -> Just (readInt t)
  _ -> Nothing
  where
    allDigits r = not (T.null r) && T.all isDigit r
    readInt = T.foldl' (\a c -> a * 10 + toInteger (fromEnum c - 48)) 0

-- | @[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?@ as a double.
parseDecimal :: Text -> Maybe Double
parseDecimal t0 = do
  let (neg, t1) = case T.uncons t0 of
        Just ('-', r) -> (True, r)
        Just ('+', r) -> (False, r)
        _ -> (False, t0)
      (ip, r1) = T.span isDigit t1
      (hasDot, r2) = case T.uncons r1 of
        Just ('.', r) -> (True, r)
        _ -> (False, r1)
      (fp, r3) = if hasDot then T.span isDigit r2 else (T.empty, r2)
  if T.null ip && T.null fp then Nothing else Just ()
  ex <- parseExp r3
  let mant = (if T.null ip then "0" else T.unpack ip) ++ "." ++ (if T.null fp then "0" else T.unpack fp)
      val = read (mant ++ "e" ++ show ex) :: Double
  Just (if neg then negate val else val)
  where
    parseExp r
      | T.null r = Just (0 :: Integer)
      | otherwise = case T.uncons r of
          Just (e, rest) | e == 'e' || e == 'E' ->
            let (sgn, ds) = case T.uncons rest of
                  Just ('-', x) -> (-1, x)
                  Just ('+', x) -> (1, x)
                  _ -> (1, rest)
             in if not (T.null ds) && T.all isDigit ds
                  then Just (sgn * T.foldl' (\a c -> a * 10 + toInteger (fromEnum c - 48)) 0 ds)
                  else Nothing
          _ -> Nothing
