-- | Semantic types and the global tables built by the item passes.
module Langvm.Types
  ( Ty (..)
  , Bound (..)
  , headPrim, headList, headMap, headDecl
  , tyHead
  , DeclKind (..)
  , DeclInfo (..)
  , MethodSig (..)
  , TraitInfo (..)
  , FnInfo (..)
  , ImplInfo (..)
  , ValueItem (..)
  , ModInfo (..)
  , Globals (..)
  , optionDecl, resultDecl
  , substTy
  , tyParamsOf
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.Map.Strict (Map)
import Data.Array (Array)

import Langvm.Builtin (Builtin)

-- | A semantic type (section 6.1).
data Ty
  = TInt | TFloat | TBool | TChar | TStr | TUnit
  | TList Ty
  | TMap Ty Ty
  | TTuple [Ty]
  | TFun [Ty] Ty
  | TNamed !Int [Ty]   -- ^ declaration id and type arguments
  | TParam !Int        -- ^ a rigid generic parameter
  | TVar !Int          -- ^ an inference variable
  deriving (Eq, Show)

-- | A bound on a type parameter.
data Bound = BEq | BOrd | BKey | BTrait !Int
  deriving (Eq, Ord, Show)

-- | Head constructor numbering: 0-5 the primitives, 6 lists, 7 maps and
-- @8 + d@ for the struct or enum declaration @d@.
headPrim :: Ty -> Maybe Int
headPrim t = case t of
  TInt -> Just 0; TFloat -> Just 1; TBool -> Just 2
  TChar -> Just 3; TStr -> Just 4; TUnit -> Just 5
  _ -> Nothing

headList, headMap :: Int
headList = 6
headMap = 7

headDecl :: Int -> Int
headDecl d = 8 + d

-- | The head constructor of a type, if it has one.
tyHead :: Ty -> Maybe Int
tyHead t = case t of
  TList _ -> Just headList
  TMap _ _ -> Just headMap
  TNamed d _ -> Just (headDecl d)
  _ -> headPrim t

data DeclKind
  = KStruct [(String, Ty)]
  | KEnum [(String, [Ty])]
  deriving (Show)

data DeclInfo = DeclInfo
  { dName :: String
  , dMod :: !Int
  , dPub :: !Bool
  , dArity :: !Int
  , dParams :: [Int]     -- ^ the parameter ids, once the signature is resolved
  , dKind :: DeclKind
  } deriving (Show)

data MethodSig = MethodSig
  { msName :: String
  , msParams :: [Ty]     -- ^ excluding @self@; @Self@ is the trait's self parameter
  , msRet :: Ty
  , msDefault :: Bool
  } deriving (Show)

data TraitInfo = TraitInfo
  { tName :: String
  , tMod :: !Int
  , tPub :: !Bool
  , tSelf :: !Int        -- ^ the parameter id standing for @Self@
  , tMethods :: [MethodSig]
  } deriving (Show)

data FnInfo = FnInfo
  { fName :: String
  , fMod :: !Int
  , fPub :: !Bool
  , fParams :: [Int]
  , fArgs :: [Ty]
  , fRet :: Ty
  , fBuiltin :: Maybe Builtin
  } deriving (Show)

data ImplInfo = ImplInfo
  { iTrait :: !Int
  , iHead :: !Int            -- ^ head constructor number
  , iParams :: [Int]
  , iHeadTy :: Ty
  , iMod :: !Int
  , iMethods :: [(Int, Int)] -- ^ (trait method index, position in the impl's method list)
  } deriving (Show)

data ValueItem
  = VIFn !Int
  | VIVariant !Int !Int      -- ^ declaration id, variant index
  deriving (Eq, Show)

data ModInfo = ModInfo
  { miName :: String
  , miTypes :: Map String Int
  , miTraits :: Map String Int
  , miValues :: Map String ValueItem
  , miImports :: Map String Int
  } deriving (Show)

-- | Everything the item passes learn about the program.
data Globals = Globals
  { gMods :: Array Int ModInfo          -- ^ index 0 is the prelude
  , gDecls :: Array Int DeclInfo
  , gTraits :: Array Int TraitInfo
  , gFns :: Array Int FnInfo
  , gImpls :: Array Int ImplInfo
  , gImplMap :: Map (Int, Int) Int      -- ^ (trait, head constructor) -> impl index
  , gParams :: IntMap (String, [Bound]) -- ^ parameter id -> name and bounds
  } deriving (Show)

-- | Declaration ids of the prelude enums (they are declared first).
optionDecl, resultDecl :: Int
optionDecl = 0
resultDecl = 1

-- | Substitute rigid parameters.
substTy :: IntMap Ty -> Ty -> Ty
substTy m = go
  where
    go t = case t of
      TList a -> TList (go a)
      TMap k v -> TMap (go k) (go v)
      TTuple ts -> TTuple (map go ts)
      TFun ps r -> TFun (map go ps) (go r)
      TNamed d as -> TNamed d (map go as)
      TParam p -> IM.findWithDefault t p m
      _ -> t

-- | The rigid parameters occurring in a type.
tyParamsOf :: Ty -> [Int]
tyParamsOf t = case t of
  TList a -> tyParamsOf a
  TMap k v -> tyParamsOf k ++ tyParamsOf v
  TTuple ts -> concatMap tyParamsOf ts
  TFun ps r -> concatMap tyParamsOf ps ++ tyParamsOf r
  TNamed _ as -> concatMap tyParamsOf as
  TParam p -> [p]
  _ -> []
