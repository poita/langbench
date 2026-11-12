-- | A static site generator.
--
-- 'generate' turns an in-memory 'SiteSource' into a list of output files;
-- 'generateSite' does the same between two directories. The building blocks
-- are exposed as modules: "Sitegen.Markdown", "Sitegen.Template",
-- "Sitegen.Toml", "Sitegen.Content", "Sitegen.Site" and "Sitegen.Feed".
--
-- > src <- loadSource "mysite"
-- > case generate src of
-- >   Left err -> putStrLn err
-- >   Right files -> writeOutput "public" files
module Sitegen
  ( -- * Generating
    generateSite
  , generate
  , SiteSource (..)
  , OutputFile (..)
    -- * Reading and writing
  , loadSource
  , writeOutput
  , copyStatic
  ) where

import Sitegen.Generate
import Sitegen.Source
