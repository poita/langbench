{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Validate
-- Description : The schema evaluator.
--
-- One recursive function, 'evalNode', takes a compiled schema node, an
-- instance and the dynamic scope, and returns an 'Outcome': rejection, or
-- acceptance together with the evaluated-items and evaluated-properties
-- annotations that @unevaluatedItems@ / @unevaluatedProperties@ consume
-- (SPEC sections 4 and 5).
module JsonSchema.Validate
  ( validate
  , validateNode
  , Outcome (..)
  , Ann (..)
  , evalNode
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map as M
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T

import JsonSchema.Json
import JsonSchema.Number
import JsonSchema.Schema

-- | Evaluated items and properties of one (schema object, instance) pair.
data Ann = Ann
  { annItems :: IS.IntSet
  , annProps :: S.Set Text
  }

instance Semigroup Ann where
  Ann a b <> Ann c d = Ann (IS.union a c) (S.union b d)

instance Monoid Ann where
  mempty = Ann IS.empty S.empty

-- | Rejection (which carries no annotations), or acceptance with annotations.
-- The 'Semigroup' instance is conjunction, short-circuiting on rejection.
data Outcome
  = Fail
  | Pass Ann

instance Semigroup Outcome where
  Fail <> _ = Fail
  Pass a <> r = case r of
    Fail -> Fail
    Pass b -> Pass (a <> b)

instance Monoid Outcome where
  mempty = Pass mempty

-- | The dynamic scope: base URIs entered so far, innermost first.
type Scope = [Text]

-- | Does the instance satisfy the schema?
validate :: Schema -> Value -> Bool
validate = validateNode . schemaRoot

-- | Does the instance satisfy this node?
validateNode :: Node -> Value -> Bool
validateNode node v = case evalNode [] node v of
  Pass _ -> True
  Fail -> False

accepts :: Outcome -> Bool
accepts Fail = False
accepts (Pass _) = True

ok :: Bool -> Outcome
ok True = mempty
ok False = Fail

-- | Apply a check only when the keyword is present.
with :: Maybe a -> (a -> Outcome) -> Outcome
with Nothing _ = mempty
with (Just x) f = f x

withIndices :: [Int] -> Outcome
withIndices is = Pass (Ann (IS.fromList is) S.empty)

withNames :: [Text] -> Outcome
withNames ns = Pass (Ann IS.empty (S.fromList ns))

-- | Evaluate a node against an instance.
evalNode :: Scope -> Node -> Value -> Outcome
evalNode _ (BoolNode b) _ = ok b
evalNode scope0 (ObjNode s) v =
  case general <> byType of
    Fail -> Fail
    Pass ann -> Pass ann <> unevaluated ann
  where
    scope = case scope0 of
      (b : _) | b == sBase s -> scope0
      _ -> sBase s : scope0

    sub = evalNode scope

    general =
      mconcat
        [ with (sType s) (\ts -> ok (any (typeMatches v) ts))
        , with (sEnum s) (\vs -> ok (v `elem` vs))
        , with (sConst s) (\c -> ok (v == c))
        , with (sRef s) (\t -> target t)
        , with (sDynamicRef s) dynamicRef
        , with (sAllOf s) (mconcat . map (\n -> sub n v))
        , with (sAnyOf s) anyOf
        , with (sOneOf s) oneOf
        , with (sNot s) (\n -> ok (not (accepts (sub n v))))
        , with (sIf s) conditional
        ]

    target (Resolved n) = sub n v
    target (Unresolved _) = Fail

    dynamicRef (DynRef Nothing t) = target t
    dynamicRef (DynRef (Just find) t) =
      case listToMaybe (mapMaybe find (reverse scope)) of
        Just n -> sub n v
        Nothing -> target t

    anyOf ns =
      let rs = [a | n <- ns, Pass a <- [sub n v]]
       in if null rs then Fail else Pass (mconcat rs)

    oneOf ns = case [a | n <- ns, Pass a <- [sub n v]] of
      [a] -> Pass a
      _ -> Fail

    conditional i = case sub i v of
      Pass a -> Pass a <> with (sThen s) (\n -> sub n v)
      Fail -> with (sElse s) (\n -> sub n v)

    byType = case v of
      Num n -> numberKeywords s n
      Str t -> stringKeywords s t
      Arr xs -> arrayKeywords sub s xs
      Obj m -> objectKeywords sub s m
      _ -> mempty

    unevaluated ann = case v of
      Arr xs ->
        with (sUnevaluatedItems s) $ \n ->
          let idxs = [i | (i, _) <- zip [0 ..] xs, not (IS.member i (annItems ann))]
              elems = [x | (i, x) <- zip [0 ..] xs, not (IS.member i (annItems ann))]
           in if all (\x -> accepts (sub n x)) elems then withIndices idxs else Fail
      Obj m ->
        with (sUnevaluatedProperties s) $ \n ->
          let rest = [(k, x) | (k, x) <- M.toList m, not (S.member k (annProps ann))]
           in if all (\(_, x) -> accepts (sub n x)) rest then withNames (map fst rest) else Fail
      _ -> mempty

typeMatches :: Value -> Text -> Bool
typeMatches v t = case (v, t) of
  (Null, "null") -> True
  (Bool _, "boolean") -> True
  (Num _, "number") -> True
  (Num n, "integer") -> isInteger n
  (Str _, "string") -> True
  (Arr _, "array") -> True
  (Obj _, "object") -> True
  _ -> False

numberKeywords :: ObjSchema -> Number -> Outcome
numberKeywords s n =
  mconcat
    [ with (sMultipleOf s) (\d -> ok (n `isMultipleOf` d))
    , with (sMaximum s) (\b -> ok (n <= b))
    , with (sMinimum s) (\b -> ok (n >= b))
    , with (sExclusiveMaximum s) (\b -> ok (n < b))
    , with (sExclusiveMinimum s) (\b -> ok (n > b))
    ]

stringKeywords :: ObjSchema -> Text -> Outcome
stringKeywords s t =
  mconcat
    [ with (sMaxLength s) (\b -> ok (compareInt b len /= LT))
    , with (sMinLength s) (\b -> ok (compareInt b len /= GT))
    , with (sPattern s) (\p -> ok (patternMatches p t))
    ]
  where
    len = T.length t

arrayKeywords :: (Node -> Value -> Outcome) -> ObjSchema -> [Value] -> Outcome
arrayKeywords sub s xs =
  mconcat
    [ with (sMaxItems s) (\b -> ok (compareInt b len /= LT))
    , with (sMinItems s) (\b -> ok (compareInt b len /= GT))
    , ok (not (sUniqueItems s) || allUnique xs)
    , with (sPrefixItems s) prefixItems
    , with (sItems s) items
    , with (sContains s) contains
    ]
  where
    len = length xs
    prefixCount = maybe 0 length (sPrefixItems s)

    prefixItems ns =
      let pairs = zip3 [0 ..] ns xs
       in if all (\(_, n, x) -> accepts (sub n x)) pairs
            then withIndices [i | (i, _, _) <- pairs]
            else Fail

    items n =
      let rest = drop prefixCount (zip [0 ..] xs)
       in if all (\(_, x) -> accepts (sub n x)) rest then withIndices (map fst rest) else Fail

    contains n =
      let hits = [i | (i, x) <- zip [0 ..] xs, accepts (sub n x)]
          cnt = length hits
          lowOk = case sMinContains s of
            Nothing -> cnt >= 1
            Just lo -> compareInt lo cnt /= GT
          highOk = case sMaxContains s of
            Nothing -> True
            Just hi -> compareInt hi cnt /= LT
       in if lowOk && highOk then withIndices hits else Fail

-- | Pairwise-distinct under JSON equality, in expected linear time: values
-- are bucketed by a hash that is consistent with equality.
allUnique :: [Value] -> Bool
allUnique = go IM.empty
  where
    go _ [] = True
    go seen (x : rest) =
      let h = hashValue x
       in case IM.lookup h seen of
            Nothing -> go (IM.insert h [x] seen) rest
            Just bucket
              | x `elem` bucket -> False
              | otherwise -> go (IM.insert h (x : bucket) seen) rest

objectKeywords :: (Node -> Value -> Outcome) -> ObjSchema -> M.Map Text Value -> Outcome
objectKeywords sub s m =
  mconcat
    [ with (sMaxProperties s) (\b -> ok (compareInt b size /= LT))
    , with (sMinProperties s) (\b -> ok (compareInt b size /= GT))
    , with (sRequired s) (\ks -> ok (all (`M.member` m) ks))
    , dependentRequired
    , properties
    , patternProps
    , with (sAdditionalProperties s) additional
    , with (sPropertyNames s) (\n -> ok (all (\k -> accepts (sub n (Str k))) (M.keys m)))
    , dependentSchemas
    ]
  where
    size = M.size m
    props = sProperties s
    pats = sPatternProperties s

    dependentRequired =
      ok (and [all (`M.member` m) reqs | (k, reqs) <- M.toList (sDependentRequired s), M.member k m])

    properties =
      let present = [(k, n, x) | (k, n) <- M.toList props, Just x <- [M.lookup k m]]
       in if all (\(_, n, x) -> accepts (sub n x)) present
            then withNames [k | (k, _, _) <- present]
            else Fail

    -- Pattern hits per member name, computed once and shared.
    hits :: M.Map Text [Node]
    hits = M.mapWithKey (\k _ -> [n | (p, n) <- pats, patternMatches p k]) m

    patternProps
      | null pats = mempty
      | otherwise =
          let matched = [(k, ns, x) | (k, x) <- M.toList m, Just ns@(_ : _) <- [M.lookup k hits]]
           in if all (\(_, ns, x) -> all (\n -> accepts (sub n x)) ns) matched
                then withNames [k | (k, _, _) <- matched]
                else Fail

    additional n =
      let rest =
            [ (k, x)
            | (k, x) <- M.toList m
            , not (M.member k props)
            , null pats || maybe True null (M.lookup k hits)
            ]
       in if all (\(_, x) -> accepts (sub n x)) rest then withNames (map fst rest) else Fail

    dependentSchemas =
      mconcat [sub n (Obj m) | (k, n) <- M.toList (sDependentSchemas s), M.member k m]
