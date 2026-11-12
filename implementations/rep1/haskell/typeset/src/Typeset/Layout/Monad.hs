-- | The layout monad: read-only environment, a mutable layout state, and the
-- primitives that turn inline text into broken, set lines.
module Typeset.Layout.Monad
  ( Env (..)
  , TextCtx (..)
  , LState (..)
  , M
  , runM
  , ask
  , get
  , modify
  , initState
  , emit
  , leaf
  , enterContainer
  , leaveContainer
  , pendMax
  , addVSpace
  , forceBreak
  , newGroup
  , groupLines
  , textLines
  , prepareText
  , breakPrepared'
  , styleOf
  , faceOf
  ) where

import qualified Data.Map.Strict as M

import Typeset.Break
import Typeset.Font
import Typeset.HList
import Typeset.Hyphenation
import Typeset.Line
import Typeset.Settings
import Typeset.Syntax
import Typeset.Types
import Typeset.Vertical

-- | Everything fixed for the run.
data Env = Env
  { envFonts :: Fonts
  , envCfg :: Settings
  , envPats :: Patterns
  }

-- | A text context for building one horizontal list.
data TextCtx = TextCtx
  { tcFamily :: Family
  , tcBold :: Bool
  , tcItalic :: Bool
  , tcSize :: !Int
  , tcLeading :: !Int
  , tcLeft :: !Int
  , tcMeasure :: !Int
  , tcAlign :: Align
  , tcFirstIndent :: !Int
  , tcHyphenate :: Bool
  }

-- | The mutable layout state.
data LState = LState
  { lsItems :: [VItem]          -- ^ reversed
  , lsGroup :: !Int
  , lsPendMax :: !Int
  , lsPendAdd :: !Int
  , lsStarted :: !Bool
  , lsCounters :: [Int]         -- ^ heading counters c1..c4
  , lsFigs :: [FigBlock]        -- ^ reversed
  , lsNotes :: M.Map Int [SetLine]
  , lsStats :: !Stats
  , lsParagraphs :: !Int
  , lsHeadings :: !Int
  , lsTables :: !Int
  }

initState :: LState
initState = LState [] 0 0 0 False [0, 0, 0, 0] [] M.empty noStats 0 0 0

newtype M a = M { unM :: Env -> LState -> (a, LState) }

instance Functor M where
  fmap f (M g) = M $ \e s -> let (a, s') = g e s in (f a, s')

instance Applicative M where
  pure a = M $ \_ s -> (a, s)
  M f <*> M g = M $ \e s -> let (h, s') = f e s; (a, s'') = g e s' in (h a, s'')

instance Monad M where
  M g >>= f = M $ \e s -> let (a, s') = g e s in unM (f a) e s'

runM :: Env -> LState -> M a -> (a, LState)
runM env st (M g) = g env st

ask :: M Env
ask = M $ \e s -> (e, s)

get :: M LState
get = M $ \_ s -> (s, s)

modify :: (LState -> LState) -> M ()
modify f = M $ \_ s -> let s' = f s in s' `seq` ((), s')

-- | Allocate a fresh group identifier.
newGroup :: M Int
newGroup = M $ \_ s -> (lsGroup s, s { lsGroup = lsGroup s + 1 })

emit :: [VItem] -> M ()
emit its = modify (\s -> s { lsItems = reverse its ++ lsItems s })

-- | Emit a leaf block's items, with the pending space rules applied.
leaf :: Int -> Int -> [VItem] -> M ()
leaf before after its = do
  s <- get
  let pm = max (lsPendMax s) before
      total = pm + lsPendAdd s
      glue = [ VGlue total | lsStarted s, total > 0 ]
  modify (\st -> st { lsPendMax = after, lsPendAdd = 0, lsStarted = True })
  emit (glue ++ its)

enterContainer, leaveContainer :: Int -> M ()
enterContainer h = pendMax h
leaveContainer h = pendMax h

-- | @pending-max = max(pending-max, h)@.
pendMax :: Int -> M ()
pendMax h = modify (\s -> s { lsPendMax = max (lsPendMax s) h })

addVSpace :: Int -> M ()
addVSpace h = modify (\s -> s { lsPendAdd = lsPendAdd s + h })

-- | A forced break: both registers are zeroed.
forceBreak :: M ()
forceBreak = do
  modify (\s -> s { lsPendMax = 0, lsPendAdd = 0 })
  emit [VForce]

styleOf :: TextCtx -> StyleState
styleOf tc = StyleState (tcFamily tc) (tcBold tc) (tcItalic tc) (tcSize tc)

faceOf :: Env -> TextCtx -> Face
faceOf env tc = resolveFace (envFonts env) (tcFamily tc) (tcBold tc) (tcItalic tc)

hparams :: Env -> TextCtx -> HParams
hparams env tc = HParams
  { hpHyphenate = tcHyphenate tc && hyphenate cfg
  , hpPatterns = envPats env
  , hpHyphenPenalty = hyphenPenalty cfg
  , hpExHyphenPenalty = exHyphenPenalty cfg
  , hpRagged = if tcAlign tc == Justify then Nothing else Just (raggedStretch cfg)
  }
  where cfg = envCfg env

bparams :: Settings -> BreakParams
bparams cfg = BreakParams (tolerance cfg) (linePenalty cfg) (adjDemerits cfg)
                          (doubleHyphenDemerits cfg) (finalHyphenDemerits cfg)

-- | Build and prepare the horizontal list of a token stream.
prepareText :: TextCtx -> [RTok] -> M Prepared
prepareText tc toks = do
  env <- ask
  return (prepare (buildList (hparams env tc) toks))

-- | Break a prepared list at the given measure and set its lines; the
-- statistics are accumulated.
breakPrepared' :: TextCtx -> Prepared -> Int -> M [SetLine]
breakPrepared' tc prep measure = do
  env <- ask
  let cfg = envCfg env
      br = breakPrepared (bparams cfg) prep measure (tcFirstIndent tc)
      lc = LineCtx (tcAlign tc) (tcLeft tc) measure (tcFirstIndent tc) (faceOf env tc) (tcSize tc)
      sls = setLines lc (preparedItems prep) (brBreaks br)
      st = Stats (brTotal br) (length (filter slHyphenated sls))
                 (length (filter slOverfull sls)) (if brEmergency br then 1 else 0)
  modify (\s -> s { lsStats = addStats (lsStats s) st })
  return sls

-- | Break and set the lines of an inline text; footnotes found in it are
-- laid out and recorded.  The prefix tokens come before the content.
textLines :: TextCtx -> [RTok] -> Inline -> M [SetLine]
textLines tc prefix inl = do
  env <- ask
  let cfg = envCfg env
  mapM_ (\(k, body) -> do ls <- footnoteLines k body
                          modify (\s -> s { lsNotes = M.insert k ls (lsNotes s) }))
        (footnotesOf inl)
  let toks = prefix ++ flatten (envFonts env) cfg (styleOf tc) inl
  prep <- prepareText tc toks
  breakPrepared' tc prep (tcMeasure tc)
  where
    footnoteLines _ body = do
      env <- ask
      let cfg = envCfg env
          fctx = TextCtx
            { tcFamily = footnoteFont cfg, tcBold = False, tcItalic = False
            , tcSize = footnoteSize cfg, tcLeading = footnoteLeading cfg
            , tcLeft = marginLeft cfg + footnoteIndent cfg
            , tcMeasure = bodyWidth cfg - footnoteIndent cfg
            , tcAlign = bodyAlign cfg, tcFirstIndent = 0
            , tcHyphenate = hyphenate cfg }
          toks = flatten (envFonts env) cfg (styleOf fctx) body
      prep <- prepareText fctx toks
      breakPrepared' fctx prep (tcMeasure fctx)

-- | Wrap set lines as the lines of one group.
groupLines :: GroupKind -> Int -> [SetLine] -> M [VItem]
groupLines kind leadingV sls = do
  g <- newGroup
  let n = length sls
  return [ VLineI (VLine (slRuns sl) (slAscent sl) (slDepth sl) leadingV g k n kind (slNotes sl) Nothing)
         | (k, sl) <- zip [1 ..] sls ]
