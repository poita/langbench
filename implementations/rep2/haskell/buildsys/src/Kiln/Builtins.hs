-- | The 39 built-in functions of KBL.
module Kiln.Builtins
  ( Builtin
  , lookupBuiltin
  , applyBuiltin
  , builtinNames
  ) where

import qualified Data.ByteString as B
import Data.Foldable (toList)
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import qualified Data.Set as S

import Kiln.Error
import Kiln.Glob
import Kiln.Text
import Kiln.Value
import Kiln.Workspace (Workspace, eligibleWithPrefix)

-- | The type an argument must have.
data Ty = TStr | TInt | TList | TAny | TStrList | TStrInt | TStrIntBool

tyName :: Ty -> B.ByteString
tyName t = case t of
  TStr -> "str"
  TInt -> "int"
  TList -> "list"
  TAny -> "any"
  TStrList -> "str|list"
  TStrInt -> "str|int"
  TStrIntBool -> "str|int|bool"

tyOk :: Ty -> Value -> Bool
tyOk t v = case (t, v) of
  (TAny, _) -> True
  (TStr, VStr _) -> True
  (TInt, VInt _) -> True
  (TList, VList _) -> True
  (TStrList, VStr _) -> True
  (TStrList, VList _) -> True
  (TStrInt, VStr _) -> True
  (TStrInt, VInt _) -> True
  (TStrIntBool, VList _) -> False
  (TStrIntBool, _) -> True
  _ -> False

-- | A built-in: accepted argument counts, argument types (the last type
-- repeats for variadic functions) and the implementation.
data Builtin = Builtin
  { bMin :: !Int
  , bMax :: !Int
  , bTypes :: [Ty]
  , bRun :: Workspace -> [Value] -> Either BuildError Value
  }

fixed :: [Ty] -> ([Value] -> Either BuildError Value) -> Builtin
fixed tys f = Builtin (length tys) (length tys) tys (const f)


-- | Look a function up by name.
lookupBuiltin :: B.ByteString -> Maybe Builtin
lookupBuiltin n = M.lookup n builtins

builtinNames :: [B.ByteString]
builtinNames = M.keys builtins

-- | Check arity and argument types, then run. Arguments are already
-- evaluated.
applyBuiltin :: Workspace -> B.ByteString -> Builtin -> [Value] -> Either BuildError Value
applyBuiltin ws name b args
  | n < bMin b || n > bMax b =
      Left (EArity "fn" name (if bMin b == bMax b then showBS (bMin b) else showBS (bMin b) <> "-" <> showBS (bMax b)) n)
  | otherwise = do
      mapM_ check (zip3 [1 :: Int ..] (bTypes b ++ repeat (last (bTypes b))) args)
      bRun b ws args
  where
    n = length args
    check (i, ty, v)
      | tyOk ty v = Right ()
      | otherwise =
          Left (EType (B.concat ["fn ", name, " argument ", showBS i]) (tyName ty) (typeName v))

showBS :: Int -> B.ByteString
showBS = renderInt

argErr :: B.ByteString -> B.ByteString -> Either BuildError a
argErr fn reason = Left (EArg "fn" fn reason)

builtins :: M.Map B.ByteString Builtin
builtins =
  M.fromList
    [ ("len", fixed [TStrList] $ \case
        [VStr s] -> ok (VInt (B.length s))
        [VList l] -> ok (VInt (Seq.length l))
        _ -> bug)
    , ("count", fixed [TList] $ \case [VList l] -> ok (VInt (Seq.length l)); _ -> bug)
    , ("upper", fixed [TStr] $ \case [VStr s] -> ok (VStr (B.map up s)); _ -> bug)
    , ("lower", fixed [TStr] $ \case [VStr s] -> ok (VStr (B.map low s)); _ -> bug)
    , ("trim", fixed [TStr] $ \case [VStr s] -> ok (VStr (trimWs s)); _ -> bug)
    , ("replace", fixed [TStr, TStr, TStr] $ \case
        [VStr s, VStr f, VStr t]
          | B.null f -> argErr "replace" "empty pattern"
          | otherwise -> ok (VStr (replaceAll f t s))
        _ -> bug)
    , ("starts_with", fixed [TStr, TStr] $ \case [VStr s, VStr p] -> ok (VBool (B.isPrefixOf p s)); _ -> bug)
    , ("ends_with", fixed [TStr, TStr] $ \case [VStr s, VStr p] -> ok (VBool (B.isSuffixOf p s)); _ -> bug)
    , ("contains", fixed [TStr, TStr] $ \case [VStr s, VStr p] -> ok (VBool (B.isInfixOf p s)); _ -> bug)
    , ("substr", fixed [TStr, TInt, TInt] $ \case
        [VStr s, VInt st, VInt c] ->
          let (a, k) = clampRange (B.length s) st c
           in ok (VStr (B.take k (B.drop a s)))
        _ -> bug)
    , ("split", fixed [TStr, TStr] $ \case
        [VStr s, VStr sep]
          | B.null sep -> argErr "split" "empty separator"
          | otherwise -> ok (VList (Seq.fromList (map VStr (splitOn sep s))))
        _ -> bug)
    , ("join", fixed [TList, TStr] $ \case
        [VList l, VStr sep] -> do
          pieces <- mapM piece (zip [0 :: Int ..] (toList l))
          ok (VStr (B.intercalate sep pieces))
        _ -> bug)
    , ("str", fixed [TStrIntBool] $ \case
        [v] | Just s <- renderScalar v -> ok (VStr s)
        _ -> bug)
    , ("int", fixed [TStrInt] $ \case
        [VInt n] -> ok (VInt n)
        [VStr s] -> maybe (argErr "int" "bad integer") (ok . VInt) (parseInt s)
        _ -> bug)
    , ("dirname", fixed [TStr] $ \case [VStr s] -> ok (VStr (dirname s)); _ -> bug)
    , ("basename", fixed [TStr] $ \case [VStr s] -> ok (VStr (basename s)); _ -> bug)
    , ("stem", fixed [TStr] $ \case [VStr s] -> ok (VStr (fst (stemExt s))); _ -> bug)
    , ("ext", fixed [TStr] $ \case [VStr s] -> ok (VStr (snd (stemExt s))); _ -> bug)
    , ("pathjoin", Builtin 1 8 [TStr] $ \_ args ->
        ok (VStr (B.intercalate "/" (filter (not . B.null) [s | VStr s <- args]))))
    , ("map", fixed [TList, TStr] $ \case
        [VList l, VStr pat] -> do
          ss <- mapM (strElem "map") (zip [0 :: Int ..] (toList l))
          ok (VList (Seq.fromList [VStr (mapPattern pat s) | s <- ss]))
        _ -> bug)
    , ("filter", fixed [TList, TStr] $ filterLike "filter" True)
    , ("reject", fixed [TList, TStr] $ filterLike "reject" False)
    , ("sort", fixed [TList] $ \case [VList l] -> ok (VList (Seq.sort l)); _ -> bug)
    , ("uniq", fixed [TList] $ \case [VList l] -> ok (VList (uniq l)); _ -> bug)
    , ("reverse", fixed [TList] $ \case [VList l] -> ok (VList (Seq.reverse l)); _ -> bug)
    , ("first", fixed [TList] $ \case
        [VList l] -> maybe (argErr "first" "empty list") ok (Seq.lookup 0 l)
        _ -> bug)
    , ("last", fixed [TList] $ \case
        [VList l] -> maybe (argErr "last" "empty list") ok (Seq.lookup (Seq.length l - 1) l)
        _ -> bug)
    , ("slice", fixed [TList, TInt, TInt] $ \case
        [VList l, VInt st, VInt c] ->
          let (a, k) = clampRange (Seq.length l) st c
           in ok (VList (Seq.take k (Seq.drop a l)))
        _ -> bug)
    , ("has", fixed [TList, TAny] $ \case
        [VList l, v] -> ok (VBool (v `elem` l))
        _ -> bug)
    , ("indexof", fixed [TList, TAny] $ \case
        [VList l, v] -> ok (VInt (maybe (-1) id (Seq.elemIndexL v l)))
        _ -> bug)
    , ("range", fixed [TInt] $ \case
        [VInt n]
          | n < 0 -> argErr "range" "negative"
          | otherwise -> ok (VList (Seq.fromFunction n VInt))
        _ -> bug)
    , ("sum", fixed [TList] $ \case
        [VList l] -> do
          ns <- mapM intElem (zip [0 :: Int ..] (toList l))
          ok (VInt (sum ns))
        _ -> bug)
    , ("flatten", fixed [TList] $ \case
        [VList l] -> ok (VList (foldMap (\case VList x -> x; v -> Seq.singleton v) l))
        _ -> bug)
    , ("zip", fixed [TList, TList] $ \case
        [VList a, VList b] -> ok (VList (Seq.zipWith (\x y -> VList (Seq.fromList [x, y])) a b))
        _ -> bug)
    , ("is_str", fixed [TAny] $ \case [VStr _] -> ok (VBool True); _ -> ok (VBool False))
    , ("is_int", fixed [TAny] $ \case [VInt _] -> ok (VBool True); _ -> ok (VBool False))
    , ("is_bool", fixed [TAny] $ \case [VBool _] -> ok (VBool True); _ -> ok (VBool False))
    , ("is_list", fixed [TAny] $ \case [VList _] -> ok (VBool True); _ -> ok (VBool False))
    , ("glob", Builtin 1 1 [TStr] $ \ws args -> case args of
        [VStr p] -> case compilePattern p of
          Nothing -> argErr "glob" "bad pattern"
          Just pat ->
            ok (VList (Seq.fromList [VStr x | x <- eligibleWithPrefix (literalPrefix pat) ws, matchPattern pat x]))
        _ -> bug)
    ]
  where
    ok = Right
    bug = error "builtin: argument types were checked"
    up b = if b >= 97 && b <= 122 then b - 32 else b
    low b = if b >= 65 && b <= 90 then b + 32 else b
    piece (_, VStr s) = ok s
    piece (_, VInt n) = ok (renderInt n)
    piece (i, v) = Left (EType (B.append "fn join element " (showBS i)) "str|int" (typeName v))
    strElem fn (i, VStr s) = const (ok s) (fn, i)
    strElem fn (i, v) = Left (EType (B.concat ["fn ", fn, " element ", showBS i]) "str" (typeName v))
    intElem (_, VInt n) = ok n
    intElem (i, v) = Left (EType (B.append "fn sum element " (showBS i)) "int" (typeName v))
    filterLike fn keep args = case args of
      [VList l, VStr p] -> case compilePattern p of
        Nothing -> argErr fn "bad pattern"
        Just pat -> do
          ss <- mapM (strElem fn) (zip [0 :: Int ..] (toList l))
          ok (VList (Seq.fromList [VStr s | s <- ss, matchPattern pat s == keep]))
      _ -> bug

trimWs :: B.ByteString -> B.ByteString
trimWs = B.dropWhileEnd ws . B.dropWhile ws
  where
    ws b = b == 32 || b == 9 || b == 10 || b == 13

-- | Resolve @(start, count)@ against a length as @substr@ and @slice@ do.
clampRange :: Int -> Int -> Int -> (Int, Int)
clampRange n start count =
  let s0 = if start < 0 then n + start else start
      s = max 0 (min n s0)
      c = max 0 (min (n - s) count)
   in (s, c)

splitOn :: B.ByteString -> B.ByteString -> [B.ByteString]
splitOn sep = go
  where
    go s =
      let (before, after) = B.breakSubstring sep s
       in if B.null after then [before] else before : go (B.drop (B.length sep) after)

parseInt :: B.ByteString -> Maybe Int
parseInt s0 = do
  let (neg, digits) = case B.uncons s0 of
        Just (45, r) -> (True, r)
        _ -> (False, s0)
  if B.null digits || not (B.all (\b -> b >= 48 && b <= 57) digits)
    then Nothing
    else do
      let v = B.foldl' (\a d -> a * 10 + fromIntegral (d - 48)) (0 :: Integer) digits
          v' = if neg then negate v else v
      if v' >= -(2 ^ (63 :: Int)) && v' < 2 ^ (63 :: Int) then Just (fromInteger v') else Nothing

dirname, basename :: B.ByteString -> B.ByteString
dirname s = case B.elemIndexEnd 47 s of
  Nothing -> B.empty
  Just i -> B.take i s
basename s = case B.elemIndexEnd 47 s of
  Nothing -> s
  Just i -> B.drop (i + 1) s

stemExt :: B.ByteString -> (B.ByteString, B.ByteString)
stemExt p =
  let b = basename p
   in case B.elemIndexEnd 46 b of
        Just i | i > 0 -> (B.take i b, B.drop i b)
        _ -> (b, B.empty)

mapPattern :: B.ByteString -> B.ByteString -> B.ByteString
mapPattern pat el = B.concat (go (B.unpack pat))
  where
    go [] = []
    go (37 : 37 : r) = "%" : go r
    go (37 : r) = el : go r
    go (x : r) = B.singleton x : go r

uniq :: Seq.Seq Value -> Seq.Seq Value
uniq = go S.empty Seq.empty . toList
  where
    go _ acc [] = acc
    go seen acc (x : xs)
      | S.member x seen = go seen acc xs
      | otherwise = go (S.insert x seen) (acc Seq.|> x) xs
