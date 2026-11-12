-- | Horizontal lists: inline text is flattened into a stream of styled
-- characters, normalised (whitespace, sentence-end glue), cut into
-- fragments, hyphenated, and turned into boxes, glue and penalties.
module Typeset.HList
  ( Sty (..)
  , StyleState (..)
  , RTok (..)
  , Item (..)
  , Box (..)
  , HParams (..)
  , flatten
  , litToks
  , buildList
  , ordinaryGlue
  , mkSty
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, toLower)
import Data.List (groupBy, sortOn)
import qualified Data.Map.Strict as M
import Data.Array

import Typeset.Font
import Typeset.Hyphenation
import Typeset.Settings
import Typeset.Syntax
import Typeset.Types
import Typeset.Units

-- | A resolved text style: face, size and raise.
data Sty = Sty { styFace :: !Face, styScale :: !Int, styRaise :: !Int }

instance Eq Sty where
  Sty f s r == Sty f' s' r' = s == s' && r == r' && f == f'

-- | The style state while scanning inline tags.
data StyleState = StyleState
  { ssFamily :: !Family, ssBold :: !Bool, ssItalic :: !Bool, ssSize :: !Int }

-- | A token of the resolved character stream (before whitespace rules).
data RTok
  = RChar !Char !Sty
  | RSp !Sty                 -- ^ one space
  | RRigid !Int              -- ^ a rigid box of the given width
  | RDisc                    -- ^ a discretionary point
  | RMark !Int !Sty          -- ^ a footnote reference mark
  | RGlueFix !Sty            -- ^ an ordinary glue that is never merged or stripped

-- | A normalised token.
data Tok
  = TChar !Char !Sty
  | TGlue !Int !Int !Int !Sty
  | TRigid !Int
  | TDisc
  | TMark !Int !Sty

-- | A box: a run of glyphs with a width (an empty text is never produced
-- except through 'IRigid').
data Box = Box
  { bxW    :: !Int
  , bxText :: String
  , bxSty  :: Sty
  , bxFrag :: !Int     -- ^ identifies the fragment it came from
  , bxNote :: !Int     -- ^ footnote number if this is a reference mark, else 0
  }

-- | An item of a horizontal list.
data Item
  = IBox Box
  | IRigidBox !Int
  | IGlue !Int !Int !Int !Bool       -- ^ width, stretch, shrink, infinite
  | IPenalty !Int !Bool (Maybe Box)  -- ^ value, flagged, pre-break text

-- | Parameters of list construction.
data HParams = HParams
  { hpHyphenate :: Bool            -- ^ context and global hyphenation both on
  , hpPatterns :: Patterns
  , hpHyphenPenalty :: !Int
  , hpExHyphenPenalty :: !Int
  , hpRagged :: Maybe Int          -- ^ @Just ragged-stretch@ when not justified
  }

mkSty :: Fonts -> StyleState -> Sty
mkSty fonts st = Sty (resolveFace fonts (ssFamily st) (ssBold st) (ssItalic st)) (ssSize st) 0

-- | Flatten inline nodes into the character stream, resolving styles.
flatten :: Fonts -> Settings -> StyleState -> Inline -> [RTok]
flatten fonts cfg = go
  where
    go st = concatMap (one st)
    one st n = case n of
      IChar c -> [RChar c (mkSty fonts st)]
      ISpace -> [RSp (mkSty fonts st)]
      IRigid -> let sty = mkSty fonts st
                in [RRigid (scale (faceSpace (styFace sty)) (styScale sty))]
      IDisc -> [RDisc]
      IStyle tag body -> go (applyTag tag st) body
      INote k _ -> let Sty f _ _ = mkSty fonts st
                   in [RMark k (Sty f (markSize cfg) (markRaise cfg))]
    applyTag tag st = case tag of
      TagBold -> st { ssBold = True }
      TagItalic -> st { ssItalic = True }
      TagMono -> st { ssFamily = Mono }
      TagLarger -> st { ssSize = stepUp (ssSize st) }
      TagSmaller -> st { ssSize = stepDown (ssSize st) }

-- | Tokens for literal text (spaces become glue).
litToks :: Sty -> String -> [RTok]
litToks sty = map (\c -> if c == ' ' then RSp sty else RChar c sty)

-- | Ordinary inter-word glue: width, stretch, shrink.
ordinaryGlue :: Sty -> (Int, Int, Int)
ordinaryGlue (Sty f s _) = (scale (faceSpace f) s, scale (faceStretch f) s, scale (faceShrink f) s)

extraGlue :: Sty -> (Int, Int, Int)
extraGlue (Sty f s _) =
  ( scale (faceSpace f + faceExtra f) s
  , scale (faceStretch f + faceStretch f `div` 2) s
  , scale (faceShrink f) s )

-- | Apply the whitespace rules and the sentence-end rule.
normalise :: [RTok] -> [Tok]
normalise = finish . trimEnds . collapse
  where
    collapse (RSp s : rest) = RSp s : collapse (dropWhile isSp rest)
    collapse (t : rest) = t : collapse rest
    collapse [] = []
    isSp (RSp _) = True
    isSp _ = False
    trimEnds ts = reverse (dropSp (reverse (dropSp ts)))
    dropSp (RSp _ : r) = r
    dropSp r = r
    finish = go []
      where
        go _ [] = []
        go prev (t : ts) =
          let out = conv prev t
          in out : go (out : prev) ts
        conv prev t = case t of
          RChar c s -> TChar c s
          RSp s -> let (w, y, z) = if sentenceEnd prev then extraGlue s else ordinaryGlue s
                   in TGlue w y z s
          RGlueFix s -> let (w, y, z) = ordinaryGlue s in TGlue w y z s
          RRigid w -> TRigid w
          RDisc -> TDisc
          RMark k s -> TMark k s
    -- prev is the reversed list of preceding normalised tokens
    sentenceEnd prev =
      case dropWhile skippable prev of
        (TChar c _ : rest) | c `elem` ".!?" ->
          case dropWhile isDisc rest of
            (TChar d _ : _) -> not (isAsciiUpper d)
            _ -> True
        _ -> False
    skippable (TDisc) = True
    skippable (TChar c _) = c `elem` ")]}'\"\8217\8221"
    skippable _ = False
    isDisc TDisc = True
    isDisc _ = False

-- | A fragment under construction.
data Frag = Frag !Sty String [Int]   -- style, reversed chars, disc positions

-- | Build the full item array of a list from its raw token stream.
buildList :: HParams -> [RTok] -> Array Int Item
buildList hp rtoks = listArray (0, length items' - 1) items'
  where
    toks = normalise rtoks
    glueItem w y z = case hpRagged hp of
      Just r -> IGlue w (r * w) 0 False
      Nothing -> IGlue w y z False
    items0 = go 0 Nothing toks
    items' = items0 ++ [IPenalty 10000 False Nothing, IGlue 0 0 0 True, IPenalty (-10000) False Nothing]

    -- go fragCounter currentFragment tokens
    go :: Int -> Maybe Frag -> [Tok] -> [Item]
    go fid cur [] = flushFrag fid cur
    go fid cur (t : ts) = case t of
      TChar c s -> case cur of
        Just (Frag s' cs ds) | s' == s -> go fid (Just (Frag s' (c : cs) ds)) ts
        _ -> flushFrag fid cur ++ go (fid + 1) (Just (Frag s [c] [])) ts
      TDisc -> case cur of
        Just (Frag s cs ds) -> go fid (Just (Frag s cs (length cs : ds))) ts
        Nothing -> go fid Nothing ts
      TGlue w y z _ -> flushFrag fid cur ++ (glueItem w y z : go (fid + 1) Nothing ts)
      TRigid w -> flushFrag fid cur ++ (IRigidBox w : go (fid + 1) Nothing ts)
      TMark k s@(Sty f sz _) ->
        let txt = show k
            b = Box (textWidth f sz txt) txt s (fid + 1) k
        in flushFrag fid cur ++ (IBox b : go (fid + 2) Nothing ts)

    flushFrag _ Nothing = []
    flushFrag fid (Just (Frag s rcs ds)) = fragItems hp fid s (reverse rcs) ds

-- | Turn one fragment into boxes and penalties.
fragItems :: HParams -> Int -> Sty -> String -> [Int] -> [Item]
fragItems hp fid sty str discs = assemble 0 str pts
  where
    f = styFace sty
    sz = styScale sty
    mkBox s = IBox (Box (textWidth f sz s) s sty fid 0)
    hyphBox = Box (charWidth f sz '-') "-" sty fid 0
    pts = hyphPoints hp sty str discs
    assemble _ s [] = [mkBox s | not (null s)]
    assemble pos s ((p, pen, pre) : rest) =
      let (a, b) = splitAt (p - pos) s
      in mkBox a : IPenalty pen True (if pre then Just hyphBox else Nothing) : assemble p b rest

-- | The hyphenation points of a fragment: (position, penalty, has pre-break
-- hyphen), sorted and deduplicated.
hyphPoints :: HParams -> Sty -> String -> [Int] -> [(Int, Int, Bool)]
hyphPoints hp (Sty f _ _) str discs
  | not gate = []
  | otherwise = dedupe (sortOn (\(p, _, pre) -> (p, pre)) allPts)
  where
    n = length str
    letter c = isAsciiLower c || isAsciiUpper c
    gate = hpHyphenate hp && faceFamily f /= Mono && any letter str
    lo = length (takeWhile (not . letter) str)
    hi = n - length (takeWhile (not . letter) (reverse str))
    core = take (hi - lo) (drop lo str)
    coreH = [ (lo + i + 1, hpExHyphenPenalty hp, False) | (i, '-') <- zip [0 ..] core ]
    explicit = M.keys (M.fromList [ (p, ()) | p <- discs, p > 0, p < n ])
    explicitPts = [ (p, hpHyphenPenalty hp, True) | p <- explicit ]
    segs = segments lo core
    liangPts
      | not (null explicit) = []
      | otherwise =
          [ (start + q, hpHyphenPenalty hp, True)
          | (start, seg) <- segs
          , not (null seg), all letter seg
          , q <- liangBreaks (hpPatterns hp) (map toLower seg) ]
    allPts = coreH ++ explicitPts ++ liangPts
    -- keep the first of equal positions; core hyphens sort first (pre == False)
    dedupe = concatMap (take 1) . groupBy (\(p, _, _) (q, _, _) -> p == q)

-- | Split a core at hyphens into (start position, segment) pairs.
segments :: Int -> String -> [(Int, String)]
segments start s = case break (== '-') s of
  (seg, []) -> [(start, seg)]
  (seg, _ : rest) -> (start, seg) : segments (start + length seg + 1) rest
