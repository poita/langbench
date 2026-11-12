{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Schema
-- Description : Compiled schemas and the schema index.
--
-- 'compileSchema' walks the root schema and every remote document once
-- (SPEC section 6.2), producing a tree of 'Node's with every keyword decoded,
-- every pattern compiled and every reference wired to its target, plus the
-- registry of resources, anchors and dynamic anchors.
--
-- The result is a knot: nodes point at their @$ref@ targets through the
-- registry, which in turn is built from the nodes.  Laziness makes this work,
-- and means each reference is resolved at most once.
module JsonSchema.Schema
  ( -- * Compiled schemas
    Schema (..)
  , Registry (..)
  , Node (..)
  , ObjSchema (..)
  , Target (..)
  , DynRef (..)
  , Pattern
  , patternMatches
    -- * Compilation
  , compileSchema
  ) where

import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T

import JsonSchema.Json (Value (..))
import JsonSchema.Number (Number, signumNumber)
import JsonSchema.Pointer (parsePointer)
import JsonSchema.Regex (Regex, compileRegex, regexSearch)
import JsonSchema.Uri

-- | A compiled schema document set: the root node and the index.
data Schema = Schema
  { schemaRoot :: Node
  , schemaRegistry :: Registry
  }

-- | The schema index.
data Registry = Registry
  { regResources :: Map Text Node
    -- ^ schema resources by base URI
  , regAnchors :: Map (Text, Text) Node
    -- ^ @$anchor@ and @$dynamicAnchor@ targets by (base URI, name)
  , regDynamic :: Map (Text, Text) Node
    -- ^ @$dynamicAnchor@ targets by (base URI, name)
  }

-- | A schema: a boolean or an object with decoded keywords.
data Node
  = BoolNode Bool
  | ObjNode ObjSchema

-- | Where a reference points; 'Unresolved' references reject everything.
data Target
  = Resolved Node
  | Unresolved Text

-- | A compiled @$dynamicRef@.
data DynRef = DynRef
  { drScopeLookup :: Maybe (Text -> Maybe Node)
    -- ^ present when the reference names a dynamic anchor: finds that anchor
    -- under a given base URI of the dynamic scope
  , drTarget :: Target
    -- ^ what the reference resolves to statically (the @$ref@ behaviour)
  }

-- | A regular expression as written in a schema.  A pattern outside the
-- supported subset never matches anything.
type Pattern = Either String Regex

patternMatches :: Pattern -> Text -> Bool
patternMatches (Right re) t = regexSearch re t
patternMatches (Left _) _ = False

-- | A schema object.  Every field corresponds to a keyword of SPEC section 5.
data ObjSchema = ObjSchema
  { sBase :: Text
  , sType :: Maybe [Text]
  , sEnum :: Maybe [Value]
  , sConst :: Maybe Value
  , sMultipleOf :: Maybe Number
  , sMaximum :: Maybe Number
  , sMinimum :: Maybe Number
  , sExclusiveMaximum :: Maybe Number
  , sExclusiveMinimum :: Maybe Number
  , sMaxLength :: Maybe Number
  , sMinLength :: Maybe Number
  , sPattern :: Maybe Pattern
  , sMaxItems :: Maybe Number
  , sMinItems :: Maybe Number
  , sUniqueItems :: Bool
  , sPrefixItems :: Maybe [Node]
  , sItems :: Maybe Node
  , sContains :: Maybe Node
  , sMaxContains :: Maybe Number
  , sMinContains :: Maybe Number
  , sMaxProperties :: Maybe Number
  , sMinProperties :: Maybe Number
  , sRequired :: Maybe [Text]
  , sDependentRequired :: Map Text [Text]
  , sProperties :: Map Text Node
  , sPatternProperties :: [(Pattern, Node)]
  , sAdditionalProperties :: Maybe Node
  , sPropertyNames :: Maybe Node
  , sDependentSchemas :: Map Text Node
  , sAllOf :: Maybe [Node]
  , sAnyOf :: Maybe [Node]
  , sOneOf :: Maybe [Node]
  , sNot :: Maybe Node
  , sIf :: Maybe Node
  , sThen :: Maybe Node
  , sElse :: Maybe Node
  , sUnevaluatedItems :: Maybe Node
  , sUnevaluatedProperties :: Maybe Node
  , sRef :: Maybe Target
  , sDynamicRef :: Maybe DynRef
  , sPointers :: Map Text Ptr
    -- ^ subschema positions, for JSON Pointer fragments
  }

-- | A position inside a schema object that a JSON Pointer can step into.
data Ptr
  = PNode Node
  | PMap (Map Text Ptr)

-- ---------------------------------------------------------------------------
-- Index entries collected during the walk

-- | Lower priority numbers win when two entries claim the same key.
data Entry
  = EResource Int Text Node
  | EAnchor Int (Text, Text) Node
  | EDynamic (Text, Text) Node

-- | Compile a root schema and a set of remote documents (retrieval URI,
-- document).  Total: malformed keyword values are treated as absent.
compileSchema :: Value -> [(Text, Value)] -> Schema
compileSchema rootDoc remotes = Schema rootNode reg
  where
    (rootNode, rootEntries) = compileDocument reg "" rootDoc
    remoteEntries = [es | (uri, doc) <- remotes, let (_, es) = compileDocument reg uri doc]
    entries = concat (rootEntries : remoteEntries)
    reg = buildRegistry entries

compileDocument :: Registry -> Text -> Value -> (Node, [Entry])
compileDocument reg retrieval doc = (node, EResource 2 retrieval node : es)
  where
    (node, es) = compileNode reg retrieval doc

buildRegistry :: [Entry] -> Registry
buildRegistry entries = Registry resources anchors dynamics
  where
    firstWins :: Ord k => [(k, Node)] -> Map k Node
    firstWins = M.fromListWith (\_new old -> old)
    resources =
      M.union
        (firstWins [(u, n) | EResource 0 u n <- entries])
        (firstWins [(u, n) | EResource 2 u n <- entries])
    anchors =
      M.union
        (firstWins [(k, n) | EAnchor 0 k n <- entries])
        (firstWins [(k, n) | EAnchor 1 k n <- entries])
    dynamics = firstWins [(k, n) | EDynamic k n <- entries]

compileNode :: Registry -> Text -> Value -> (Node, [Entry])
compileNode _ _ (Bool b) = (BoolNode b, [])
compileNode reg base0 (Obj m) = compileObject reg base0 m
compileNode _ _ _ = (BoolNode True, [])

-- | Subschema children of an object, by keyword.
data Kids
  = One Node
  | Many [Node]
  | Named (Map Text Node)

singleKeywords, listKeywords, mapKeywords :: [Text]
singleKeywords =
  [ "additionalProperties", "propertyNames", "items", "contains", "not", "if", "then", "else"
  , "unevaluatedItems", "unevaluatedProperties", "contentSchema" ]
listKeywords = ["allOf", "anyOf", "oneOf", "prefixItems"]
mapKeywords = ["$defs", "properties", "patternProperties", "dependentSchemas"]

isSchemaValue :: Value -> Bool
isSchemaValue (Bool _) = True
isSchemaValue (Obj _) = True
isSchemaValue _ = False

compileObject :: Registry -> Text -> Map Text Value -> (Node, [Entry])
compileObject reg base0 m = (node, ownEntries ++ concat kidEntries)
  where
    node = ObjNode obj

    -- The base URI in force for this object (SPEC 6.1).
    idValue = case M.lookup "$id" m of
      Just (Str s) -> Just s
      _ -> Nothing
    base = case idValue of
      Just s -> renderUri (withoutFragment (resolve (parseUri base0) (parseUri s)))
      Nothing -> base0

    ownEntries =
      [EResource 0 base node | Just _ <- [idValue], base /= base0]
        ++ [EAnchor 0 (base, a) node | Just (Str a) <- [M.lookup "$anchor" m]]
        ++ concat [[EDynamic (base, a) node, EAnchor 1 (base, a) node] | Just (Str a) <- [M.lookup "$dynamicAnchor" m]]

    -- Compile every subschema position of SPEC 6.2.
    compiled :: [(Text, (Kids, [Entry]))]
    compiled =
      [ (k, (One n, es))
      | k <- singleKeywords, Just v <- [M.lookup k m], isSchemaValue v, let (n, es) = compileNode reg base v ]
        ++ [ (k, (Many (map fst rs), concatMap snd rs))
           | k <- listKeywords, Just (Arr vs) <- [M.lookup k m], let rs = map (compileNode reg base) vs ]
        ++ [ (k, (Named (M.map fst rs), concatMap snd (M.elems rs)))
           | k <- mapKeywords, Just (Obj mm) <- [M.lookup k m], let rs = M.map (compileNode reg base) mm ]
    kids = M.fromList [(k, ks) | (k, (ks, _)) <- compiled]
    kidEntries = [es | (_, (_, es)) <- compiled]

    one k = case M.lookup k kids of Just (One n) -> Just n; _ -> Nothing
    many k = case M.lookup k kids of Just (Many ns) -> Just ns; _ -> Nothing
    named k = case M.lookup k kids of Just (Named nm) -> nm; _ -> M.empty

    number k = case M.lookup k m of Just (Num n) -> Just n; _ -> Nothing
    names xs = [s | Str s <- xs]

    pointers = M.map toPtr kids
    toPtr (One n) = PNode n
    toPtr (Many ns) = PMap (M.fromList (zip (map (T.pack . show) [0 :: Int ..]) (map PNode ns)))
    toPtr (Named nm) = PMap (M.map PNode nm)

    obj =
      ObjSchema
        { sBase = base
        , sType = case M.lookup "type" m of
            Just (Str t) -> Just [t]
            Just (Arr ts) -> Just (names ts)
            _ -> Nothing
        , sEnum = case M.lookup "enum" m of Just (Arr xs) -> Just xs; _ -> Nothing
        , sConst = M.lookup "const" m
        , sMultipleOf = case number "multipleOf" of
            Just n | signumNumber n > 0 -> Just n
            _ -> Nothing
        , sMaximum = number "maximum"
        , sMinimum = number "minimum"
        , sExclusiveMaximum = number "exclusiveMaximum"
        , sExclusiveMinimum = number "exclusiveMinimum"
        , sMaxLength = number "maxLength"
        , sMinLength = number "minLength"
        , sPattern = case M.lookup "pattern" m of Just (Str p) -> Just (compileRegex p); _ -> Nothing
        , sMaxItems = number "maxItems"
        , sMinItems = number "minItems"
        , sUniqueItems = M.lookup "uniqueItems" m == Just (Bool True)
        , sPrefixItems = many "prefixItems"
        , sItems = one "items"
        , sContains = one "contains"
        , sMaxContains = number "maxContains"
        , sMinContains = number "minContains"
        , sMaxProperties = number "maxProperties"
        , sMinProperties = number "minProperties"
        , sRequired = case M.lookup "required" m of Just (Arr xs) -> Just (names xs); _ -> Nothing
        , sDependentRequired = case M.lookup "dependentRequired" m of
            Just (Obj mm) -> M.mapMaybe (\v -> case v of Arr xs -> Just (names xs); _ -> Nothing) mm
            _ -> M.empty
        , sProperties = named "properties"
        , sPatternProperties = [(compileRegex k, n) | (k, n) <- M.toList (named "patternProperties")]
        , sAdditionalProperties = one "additionalProperties"
        , sPropertyNames = one "propertyNames"
        , sDependentSchemas = named "dependentSchemas"
        , sAllOf = many "allOf"
        , sAnyOf = many "anyOf"
        , sOneOf = many "oneOf"
        , sNot = one "not"
        , sIf = one "if"
        , sThen = one "then"
        , sElse = one "else"
        , sUnevaluatedItems = one "unevaluatedItems"
        , sUnevaluatedProperties = one "unevaluatedProperties"
        , sRef = case M.lookup "$ref" m of Just (Str r) -> Just (resolveRef reg base r); _ -> Nothing
        , sDynamicRef = case M.lookup "$dynamicRef" m of Just (Str r) -> Just (compileDynamicRef reg base r); _ -> Nothing
        , sPointers = pointers
        }

-- ---------------------------------------------------------------------------
-- References

-- | Split a reference, resolved against a base, into document part and
-- decoded fragment.
splitRef :: Text -> Text -> (Text, Text)
splitRef base ref = splitFragment (resolve (parseUri base) (parseUri ref))

resolveRef :: Registry -> Text -> Text -> Target
resolveRef reg base ref =
  maybe (Unresolved ref) Resolved (lookupRef reg doc frag)
  where
    (doc, frag) = splitRef base ref

lookupRef :: Registry -> Text -> Text -> Maybe Node
lookupRef reg doc frag
  | T.null frag = M.lookup doc (regResources reg)
  | "/" `T.isPrefixOf` frag = do
      root <- M.lookup doc (regResources reg)
      toks <- parsePointer frag
      follow root toks
  | otherwise = M.lookup (doc, frag) (regAnchors reg)

-- Walk a JSON Pointer through the subschema positions of a compiled node.
follow :: Node -> [Text] -> Maybe Node
follow n [] = Just n
follow (BoolNode _) _ = Nothing
follow (ObjNode o) (k : ks) = M.lookup k (sPointers o) >>= step ks
  where
    step rest (PNode n) = follow n rest
    step rest (PMap mm) = case rest of
      [] -> Nothing
      (t : ts) -> M.lookup t mm >>= step ts

compileDynamicRef :: Registry -> Text -> Text -> DynRef
compileDynamicRef reg base ref = DynRef scopeLookup (resolveRef reg base ref)
  where
    (doc, frag) = splitRef base ref
    isPlainName = not (T.null frag) && not ("/" `T.isPrefixOf` frag)
    scopeLookup
      | isPlainName && M.member (doc, frag) (regDynamic reg) =
          Just (\b -> M.lookup (b, frag) (regDynamic reg))
      | otherwise = Nothing
