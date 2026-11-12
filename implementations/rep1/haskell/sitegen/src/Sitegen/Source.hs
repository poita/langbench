{-# LANGUAGE OverloadedStrings #-}

-- | Reading a site from disk and writing the result.
module Sitegen.Source
  ( loadSource
  , writeOutput
  , copyStatic
  , generateSite
  ) where

import Control.Monad (filterM, forM, forM_, unless)
import qualified Data.ByteString as B
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Directory
import System.FilePath

import Sitegen.Generate

readText :: FilePath -> IO Text
readText p = TE.decodeUtf8With TE.lenientDecode <$> B.readFile p

-- | The regular files directly inside a directory (nothing if it does not
-- exist) whose names end with a suffix, in name order.
filesWithSuffix :: String -> FilePath -> IO [FilePath]
filesWithSuffix suffix dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      names <- sort <$> listDirectory dir
      filterM (\n -> doesFileExist (dir </> n)) (filter (isSuffixOf suffix) names)

-- | Read @site.toml@, the content files and the templates.
loadSource :: FilePath -> IO SiteSource
loadSource input = do
  config <- readText (input </> "site.toml")
  let readAll dir names = forM names $ \n -> (,) n <$> readText (dir </> n)
      postsDir = input </> "content" </> "posts"
      pagesDir = input </> "content" </> "pages"
      tplDir = input </> "templates"
  posts <- filesWithSuffix ".md" postsDir >>= readAll postsDir
  pages <- filesWithSuffix ".md" pagesDir >>= readAll pagesDir
  tpls <- filesWithSuffix ".html" tplDir >>= readAll tplDir
  pure (SiteSource config posts pages [(T.pack n, dropOneNewline t) | (n, t) <- tpls])
  where
    -- a template's source has one trailing newline removed
    dropOneNewline t = maybe t id (T.stripSuffix "\n" t)

-- | Write generated files below the output directory.
writeOutput :: FilePath -> [OutputFile] -> IO ()
writeOutput out files = forM_ files $ \f -> do
  let path = out </> outPath f
  createDirectoryIfMissing True (takeDirectory path)
  B.writeFile path (TE.encodeUtf8 (outContents f))

-- | Copy every file under @static/@ to the same relative path in the output
-- directory, byte for byte.
copyStatic :: FilePath -> FilePath -> IO ()
copyStatic input out = do
  let root = input </> "static"
  exists <- doesDirectoryExist root
  unless (not exists) (go root "")
  where
    go root rel = do
      let dir = if null rel then root else root </> rel
      names <- listDirectory dir
      forM_ names $ \n -> do
        let relPath = if null rel then n else rel </> n
            src = root </> relPath
        isDir <- doesDirectoryExist src
        if isDir
          then go root relPath
          else do
            let dst = out </> relPath
            createDirectoryIfMissing True (takeDirectory dst)
            copyFile src dst

-- | Generate the site in @input@ into the directory @out@.
generateSite :: FilePath -> FilePath -> IO (Either String ())
generateSite input out = do
  src <- loadSource input
  case generate src of
    Left err -> pure (Left err)
    Right files -> do
      createDirectoryIfMissing True out
      writeOutput out files
      copyStatic input out
      pure (Right ())
