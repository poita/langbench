-- | The 39 built-in functions of KBL.
module Kiln.Builtins
  ( Builtin (..)
  , Ty (..)
  , lookupBuiltin
  , builtinNames
  , tyName
  , tyAccepts
  , paramType
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (findIndex)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Kiln.Command (replaceAll)
import Kiln.Error
import Kiln.Glob
import Kiln.Value
import Kiln.Workspace (Workspace, globCandidates)

-- | The type of a parameter.
data Ty = TStr | TInt | TBool | TList | TAny | TStrOrList | TStrOrInt | TScalar
  deriving (Eq, Show)

-- | The type token printed in @E_TYPE@.
tyName :: Ty -> BS.ByteString
tyName t = case t of
  TStr -> "str"
  TInt -> "int"
  TBool -> "bool"
  TList -> "list"
  TAny -> "any"
  TStrOrList -> "str|list"
  TStrOrInt -> "str|int"
  TScalar -> "str|int|bool"

tyAccepts :: Ty -> Value -> Bool
tyAccepts t v = case (t, v) of
  (TAny, _) -> True
  (TStr, VStr _) -> True
  (TInt, VInt _) -> True
  (TBool, VBool _) -> True
  (TList, VList _) -> True
  (TStrOrList, VStr _) -> True
  (TStrOrList, VList _) -> True
  (TStrOrInt, VStr _) -> True
  (TStrOrInt, VInt _) -> True
  (TScalar, VList _) -> False
  (TScalar, _) -> True
  _ -> False

-- | A built-in function: arity range, parameter types and implementation.
-- The implementation receives type-checked arguments.
data Builtin = Builtin
  { bName :: !BS.ByteString
  , bMinArgs :: !Int
  , bMaxArgs :: !Int
  , bParams :: [Ty]
  , bRun :: Workspace -> [Value] -> Either KilnError Value
  }

-- | The type of the @i@-th (0-based) parameter.
paramType :: Builtin -> Int -> Ty
paramType b i = case drop i (bParams b) of
  t : _ -> t
  [] -> case reverse (bParams b) of
    t : _ -> t
    [] -> TAny

lookupBuiltin :: BS.ByteString -> Maybe Builtin
lookupBuiltin n = Map.lookup n table

builtinNames :: [BS.ByteString]
builtinNames = Map.keys table

table :: Map.Map BS.ByteString Builtin
table = Map.fromList [(bName b, b) | b <- builtins]

internal :: Either KilnError a
internal = Left (EInternal "builtin argument mismatch")

fn1 :: BS.ByteString -> Ty -> (Value -> Either KilnError Value) -> Builtin
fn1 n t f = Builtin n 1 1 [t] $ \_ vs -> case vs of [a] -> f a; _ -> internal

fn2 :: BS.ByteString -> Ty -> Ty -> (Value -> Value -> Either KilnError Value) -> Builtin
fn2 n t1 t2 f = Builtin n 2 2 [t1, t2] $ \_ vs -> case vs of [a, b] -> f a b; _ -> internal

fn3 :: BS.ByteString -> Ty -> Ty -> Ty -> (Value -> Value -> Value -> Either KilnError Value) -> Builtin
fn3 n t1 t2 t3 f = Builtin n 3 3 [t1, t2, t3] $ \_ vs -> case vs of [a, b, c] -> f a b c; _ -> internal

sOf :: Value -> BS.ByteString
sOf (VStr s) = s
sOf _ = BS.empty

iOf :: Value -> Int64
iOf (VInt n) = n
iOf _ = 0

lOf :: Value -> Seq.Seq Value
lOf (VList l) = l
lOf _ = Seq.empty

bool :: Bool -> Either KilnError Value
bool = Right . VBool

str :: BS.ByteString -> Either KilnError Value
str = Right . VStr

list :: [Value] -> Either KilnError Value
list = Right . VList . Seq.fromList

argErr :: BS.ByteString -> BS.ByteString -> BS.ByteString -> Either KilnError a
argErr name reason _ = Left (EArg "fn" name reason)

int64 :: Int -> Int64
int64 = fromIntegral

-- | The clamping rule shared by @substr@ and @slice@.
window :: Int -> Int64 -> Int64 -> (Int, Int)
window n start count = (fromIntegral s, fromIntegral c)
  where
    n' = int64 n
    s0 = if start < 0 then n' + start else start
    s = max 0 (min n' s0)
    c = max 0 (min (n' - s) count)

splitOnSep :: BS.ByteString -> BS.ByteString -> [BS.ByteString]
splitOnSep sep s = case BS.breakSubstring sep s of
  (pre, rest)
    | BS.null rest -> [pre]
    | otherwise -> pre : splitOnSep sep (BS.drop (BS.length sep) rest)

basenameOf, dirnameOf :: BS.ByteString -> BS.ByteString
basenameOf p = case BC.elemIndexEnd '/' p of
  Nothing -> p
  Just i -> BS.drop (i + 1) p
dirnameOf p = case BC.elemIndexEnd '/' p of
  Nothing -> BS.empty
  Just i -> BS.take i p

-- | (stem, ext) of a path.
stemExt :: BS.ByteString -> (BS.ByteString, BS.ByteString)
stemExt p = case BC.elemIndexEnd '.' b of
  Just i | i > 0 -> (BS.take i b, BS.drop i b)
  _ -> (b, BS.empty)
  where
    b = basenameOf p

mapPattern :: BS.ByteString -> BS.ByteString -> BS.ByteString
mapPattern pat el = BS.concat (go pat)
  where
    go p = case BC.elemIndex '%' p of
      Nothing -> [p]
      Just i ->
        let (pre, r) = BS.splitAt i p
         in if "%%" `BS.isPrefixOf` r
              then pre : "%" : go (BS.drop 2 r)
              else pre : el : go (BS.drop 1 r)

parseInt :: BS.ByteString -> Maybe Int64
parseInt s
  | BS.null digits || not (BC.all (\c -> c >= '0' && c <= '9') digits) = Nothing
  | v < toInteger (minBound :: Int64) || v > toInteger (maxBound :: Int64) = Nothing
  | otherwise = Just (fromInteger v)
  where
    (neg, digits) = case BC.uncons s of
      Just ('-', r) -> (True, r)
      _ -> (False, s)
    v0 = BC.foldl' (\a c -> a * 10 + toInteger (fromEnum c - 48)) 0 digits
    v = if neg then negate v0 else v0

isWs :: Char -> Bool
isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

elementType :: BS.ByteString -> Int -> BS.ByteString -> Value -> Either KilnError a
elementType fn i expected v =
  Left (EType ("fn " <> fn <> " element " <> BC.pack (show i)) expected (typeName v))

globFilter :: BS.ByteString -> Bool -> Value -> Value -> Either KilnError Value
globFilter name keep lv pv = case compilePattern (sOf pv) of
  Nothing -> Left (EArg "fn" name "bad pattern")
  Just pat -> do
    kept <- mapM (test pat) (zip [0 ..] (toList (lOf lv)))
    list [v | (True, v) <- kept]
  where
    test pat (i, v) = case v of
      VStr s -> Right (matchPattern pat s == keep, v)
      _ -> elementType name i "str" v

builtins :: [Builtin]
builtins =
  [ fn1 "len" TStrOrList $ \v -> Right $ VInt $ case v of
      VStr s -> int64 (BS.length s)
      VList l -> int64 (Seq.length l)
      _ -> 0
  , fn1 "count" TList $ \v -> Right (VInt (int64 (Seq.length (lOf v))))
  , fn1 "upper" TStr $ \v -> str (BC.map toUpperAscii (sOf v))
  , fn1 "lower" TStr $ \v -> str (BC.map toLowerAscii (sOf v))
  , fn1 "trim" TStr $ \v -> str (BC.dropWhileEnd isWs (BC.dropWhile isWs (sOf v)))
  , fn3 "replace" TStr TStr TStr $ \s from to ->
      if BS.null (sOf from)
        then argErr "replace" "empty pattern" ""
        else str (replaceAll (sOf from) (sOf to) (sOf s))
  , fn2 "starts_with" TStr TStr $ \s p -> bool (sOf p `BS.isPrefixOf` sOf s)
  , fn2 "ends_with" TStr TStr $ \s p -> bool (sOf p `BS.isSuffixOf` sOf s)
  , fn2 "contains" TStr TStr $ \s p -> bool (sOf p `BS.isInfixOf` sOf s)
  , fn3 "substr" TStr TInt TInt $ \s a c ->
      let (st, n) = window (BS.length (sOf s)) (iOf a) (iOf c)
       in str (BS.take n (BS.drop st (sOf s)))
  , fn2 "split" TStr TStr $ \s sep ->
      if BS.null (sOf sep)
        then argErr "split" "empty separator" ""
        else list (map VStr (splitOnSep (sOf sep) (sOf s)))
  , fn2 "join" TList TStr $ \l sep -> do
      parts <- mapM piece (zip [0 ..] (toList (lOf l)))
      str (BS.intercalate (sOf sep) parts)
  , fn1 "str" TScalar $ \v -> maybe internal str (valueText v)
  , fn1 "int" TStrOrInt $ \v -> case v of
      VInt _ -> Right v
      VStr s -> maybe (argErr "int" "bad integer" "") (Right . VInt) (parseInt s)
      _ -> internal
  , fn1 "dirname" TStr $ \v -> str (dirnameOf (sOf v))
  , fn1 "basename" TStr $ \v -> str (basenameOf (sOf v))
  , fn1 "stem" TStr $ \v -> str (fst (stemExt (sOf v)))
  , fn1 "ext" TStr $ \v -> str (snd (stemExt (sOf v)))
  , Builtin "pathjoin" 1 8 [TStr] $ \_ vs ->
      str (BS.intercalate "/" (filter (not . BS.null) (map sOf vs)))
  , fn2 "map" TList TStr $ \l pat -> do
      out <- mapM (el (sOf pat)) (zip [0 ..] (toList (lOf l)))
      list out
  , fn2 "filter" TList TStr (globFilter "filter" True)
  , fn2 "reject" TList TStr (globFilter "reject" False)
  , fn1 "sort" TList $ \v -> Right (VList (Seq.sort (lOf v)))
  , fn1 "uniq" TList $ \v -> list (uniqValues (toList (lOf v)))
  , fn1 "reverse" TList $ \v -> Right (VList (Seq.reverse (lOf v)))
  , fn1 "first" TList $ \v -> case Seq.viewl (lOf v) of
      x Seq.:< _ -> Right x
      Seq.EmptyL -> argErr "first" "empty list" ""
  , fn1 "last" TList $ \v -> case Seq.viewr (lOf v) of
      _ Seq.:> x -> Right x
      Seq.EmptyR -> argErr "last" "empty list" ""
  , fn3 "slice" TList TInt TInt $ \l a c ->
      let (st, n) = window (Seq.length (lOf l)) (iOf a) (iOf c)
       in Right (VList (Seq.take n (Seq.drop st (lOf l))))
  , fn2 "has" TList TAny $ \l v -> bool (any (== v) (lOf l))
  , fn2 "indexof" TList TAny $ \l v ->
      Right (VInt (maybe (-1) int64 (findIndex (== v) (toList (lOf l)))))
  , fn1 "range" TInt $ \v ->
      if iOf v < 0 then argErr "range" "negative" "" else list (map VInt [0 .. iOf v - 1])
  , fn1 "sum" TList $ \l -> do
      ns <- mapM summand (zip [0 ..] (toList (lOf l)))
      Right (VInt (foldl (+) 0 ns))
  , fn1 "flatten" TList $ \l ->
      list (concatMap (\v -> case v of VList xs -> toList xs; _ -> [v]) (toList (lOf l)))
  , fn2 "zip" TList TList $ \a b ->
      list [VList (Seq.fromList [x, y]) | (x, y) <- zip (toList (lOf a)) (toList (lOf b))]
  , fn1 "is_str" TAny $ \v -> bool (case v of VStr _ -> True; _ -> False)
  , fn1 "is_int" TAny $ \v -> bool (case v of VInt _ -> True; _ -> False)
  , fn1 "is_bool" TAny $ \v -> bool (case v of VBool _ -> True; _ -> False)
  , fn1 "is_list" TAny $ \v -> bool (case v of VList _ -> True; _ -> False)
  , Builtin "glob" 1 1 [TStr] $ \ws vs -> case vs of
      [p] -> case compilePattern (sOf p) of
        Nothing -> argErr "glob" "bad pattern" ""
        Just pat ->
          list
            [ VStr c
            | c <- globCandidates (literalPrefix (sOf p)) ws
            , matchPattern pat c
            ]
      _ -> internal
  ]
  where
    piece (i, v) = case v of
      VStr s -> Right s
      VInt n -> Right (BC.pack (show n))
      _ -> elementType "join" i "str|int" v
    el pat (i, v) = case v of
      VStr s -> Right (VStr (mapPattern pat s))
      _ -> elementType "map" i "str" v
    summand (i, v) = case v of
      VInt n -> Right n
      _ -> elementType "sum" i "int" v

toUpperAscii, toLowerAscii :: Char -> Char
toUpperAscii c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

uniqValues :: [Value] -> [Value]
uniqValues = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs
