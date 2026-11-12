-- | The Codexa typesetting engine.
--
-- The public entry points are 'loadResources' (fonts and hyphenation
-- patterns from a @data@ directory), 'typeset' (settings text and document
-- text in, rendered output files out) and 'runDirectory' (the file-level
-- contract used by the command-line tool).
--
-- > res <- loadResources "data"
-- > case typeset res Nothing (Just "Hello, world.\n") of
-- >   Left err  -> putStrLn (renderError err)
-- >   Right out -> putStr (outLayout out)
module Typeset
  ( Resources (..)
  , Output (..)
  , loadResources
  , typeset
  , runDirectory
    -- * Re-exports
  , Error (..)
  , renderError
  ) where

import Data.Array (listArray)
import qualified Data.Map.Strict as M
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO

import Typeset.Error
import Typeset.Font
import Typeset.Header
import Typeset.Hyphenation
import Typeset.Layout
import Typeset.Layout.Monad (Env (..))
import Typeset.Output
import Typeset.Page
import Typeset.Parser
import Typeset.Settings
import Typeset.Syntax
import Typeset.Units (roman)
import Typeset.Vertical

-- | Fonts and hyphenation patterns.
data Resources = Resources
  { resFonts :: Fonts
  , resPatterns :: PatternSets
  }

-- | The two output files of a successful run.
data Output = Output
  { outLayout :: String
  , outReport :: String
  }

-- | Load the font faces and pattern sets from @\<dir\>/faces@ and
-- @\<dir\>/hyphen@.
loadResources :: FilePath -> IO Resources
loadResources dir = Resources <$> loadFonts dir <*> loadPatterns dir

-- | Typeset a document.  The first text is the optional @settings.cfg@, the
-- second the @document.cdx@ (@Nothing@ reports @missing-document@).
typeset :: Resources -> Maybe String -> Maybe String -> Either Error Output
typeset _ _ Nothing = Left (Error NoFile 0 0 MissingDocument)
typeset res mSettings (Just docText) = do
  cfg <- parseSettings (maybe "" id mSettings)
  doc <- parseDocument docText
  return (layoutDocument res cfg doc)

layoutDocument :: Resources -> Settings -> Doc -> Output
layoutDocument res cfg doc =
  let fonts = resFonts res
      pats = patternsFor (resPatterns res) (hyphenPatterns cfg)
      env = Env fonts cfg pats
      body = layoutBody env (docBlocks doc)
      figArr = listArray (1, length (blFigures body)) (blFigures body)
      (bodyPages, splitLines) = paginate fonts cfg figArr (blNotes body) (blItems body)
      nBody = length bodyPages
      labelOf m = pageStart cfg + m - 1
      -- table of contents
      entries = [ TocEntry info (show (labelOf m))
                | (m, pg) <- zip [1 ..] bodyPages, info <- pbHeads pg
                , not (hiStar info), hiLevel info <= tocDepth cfg ]
      (tocPages, tocStats) = case docToc doc of
        Nothing -> ([], noStats)
        Just mt ->
          let title = maybe (tocTitle cfg) id mt
              (items, st) = layoutToc env title entries
              (pgs, _) = paginate fonts cfg (listArray (1, 0) []) M.empty items
          in (pgs, st)
      nFront = length tocPages
      meta = docMeta doc
      mk label number chap sect pg =
        PageRecord label (pbItems pg ++ headerFooterItems fonts pats cfg meta (PageInfo label number nBody chap sect))
      frontRecords = [ mk (roman m) m "" "" pg | (m, pg) <- zip [1 ..] tocPages ]
      bodyRecords = go "" "" (zip [1 ..] bodyPages)
        where
          go _ _ [] = []
          go chap sect ((m, pg) : rest) =
            let chap' = foldl (\c h -> if hiLevel h == 1 then headText h else c) chap (pbHeads pg)
                sect' = foldl (\s h -> if hiLevel h == 2 then headText h else s) sect (pbHeads pg)
            in mk (show (labelOf m)) (labelOf m) chap' sect' pg : go chap' sect' rest
          headText h = if null (hiNumber h) then hiPlain h else hiNumber h ++ " " ++ hiPlain h
      records = frontRecords ++ bodyRecords
      st = addStats (blStats body) tocStats
      report = Report
        { rpFrontPages = nFront, rpBodyPages = nBody
        , rpLines = sum (map pbLines (tocPages ++ bodyPages))
        , rpParagraphs = blParagraphs body, rpHeadings = blHeadings body, rpTables = blTables body
        , rpFigures = length (blFigures body), rpFootnotes = M.size (blNotes body)
        , rpSplitLines = splitLines
        , rpHyphenated = stHyphenated st, rpOverfull = stOverfull st
        , rpEmergency = stEmergency st, rpDemerits = stDemerits st }
  in Output (renderLayout cfg records) (renderReport report)

-- | The file-level contract: read @document.cdx@ and the optional
-- @settings.cfg@ from the input directory, write either @error.txt@ or
-- @layout.txt@ and @report.txt@ into the output directory.  Fonts and
-- patterns are read from the given data directory.
runDirectory :: FilePath -> FilePath -> FilePath -> IO ()
runDirectory dataDir inDir outDir = do
  createDirectoryIfMissing True outDir
  hasDoc <- doesFileExist (inDir </> "document.cdx")
  hasCfg <- doesFileExist (inDir </> "settings.cfg")
  res <- loadResources dataDir
  mdoc <- if hasDoc then Just <$> ioReadUtf8 (inDir </> "document.cdx") else return Nothing
  mcfg <- if hasCfg then Just <$> ioReadUtf8 (inDir </> "settings.cfg") else return Nothing
  case typeset res mcfg mdoc of
    Left e -> writeUtf8 (outDir </> "error.txt") (renderError e ++ "\n")
    Right o -> do
      writeUtf8 (outDir </> "layout.txt") (outLayout o)
      writeUtf8 (outDir </> "report.txt") (outReport o)

writeUtf8 :: FilePath -> String -> IO ()
writeUtf8 path s = withFile path WriteMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  hPutStr h s
