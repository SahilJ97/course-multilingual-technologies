{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Clay (Css, em, px, sym, (?))
import qualified Clay as C
import Control.Monad
import Data.Aeson (FromJSON, fromJSON)
import Data.Maybe (fromMaybe)
import qualified Data.Aeson as Aeson
import Data.Text (Text, intercalate, strip)
import qualified Data.Text as T
import Development.Shake
import GHC.Generics (Generic)
import Lucid
import Main.Utf8
import Rib (IsRoute, Pandoc)
import qualified Rib
import qualified Rib.Parser.Pandoc as Pandoc
import System.FilePath

-- | Route corresponding to each generated static page.
--
-- The `a` parameter specifies the data (typically Markdown document) used to
-- generate the final page text.
data Route a where
  Route_Index :: Route [(Route Pandoc, Pandoc)]
  Route_Article :: FilePath -> Route Pandoc

-- | The `IsRoute` instance allows us to determine the target .html path for
-- each route. This affects what `routeUrl` will return.
instance IsRoute Route where
  routeFile = \case
    Route_Index ->
      pure "index.html"
    Route_Article srcPath ->
      pure $ "article" </> srcPath -<.> ".html"

-- | Main entry point to our generator.
--
-- `Rib.run` handles CLI arguments, and takes three parameters here.
--
-- 1. Directory `content`, from which static files will be read.
-- 2. Directory `dest`, under which target files will be generated.
-- 3. Shake action to run.
--
-- In the shake action you would expect to use the utility functions
-- provided by Rib to do the actual generation of your static site.
main :: IO ()
main = withUtf8 $ do
  Rib.run "content" "dest" generateSite

-- | Shake action for generating the static site
generateSite :: Action ()
generateSite = do
  -- Copy over the static files
  Rib.buildStaticFiles ["static/**"]
  let writeHtmlRoute :: Route a -> a -> Action ()
      writeHtmlRoute r = Rib.writeRoute r . Lucid.renderText . renderPage r
  -- Build individual sources, generating .html for each.
  articles <-
    Rib.forEvery ["*.md"] $ \srcPath -> do
      let r = Route_Article srcPath
      doc <- Pandoc.parse Pandoc.readMarkdown srcPath
      writeHtmlRoute r doc
      pure (r, doc)
  writeHtmlRoute Route_Index articles

-- | Define your site HTML here
renderPage :: Route a -> a -> Html ()
renderPage route val = html_ [lang_ "en"] $ do
  head_ $ do
    meta_ [httpEquiv_ "Content-Type", content_ "text/html; charset=utf-8"]
    title_ routeTitle
    link_ [rel_ "stylesheet", href_ "https://cdnjs.cloudflare.com/ajax/libs/tufte-css/1.7.2/tufte.min.css"]
    style_ [type_ "text/css"] $ C.render pageStyle
  body_ $ do
    h1_ routeTitle
    pageContent
    footer_ $ p_ $ do
      "All text ©2021 by respective authors. Site assembled by "
      a_ [href_ "https://jonreeve.com/"] "Jonathan Reeve"
      " using "
      a_ [href_ "https://www.haskell.org/"] "Haskell"
      " and "
      a_ [href_ "https://github.com/srid/rib"] "Rib,"
      " with source code available "
      a_ [href_ "https://github.com/JonathanReeve/course-multilingual-technologies/"] "here on GitHub. "
      "We thank the "
      a_ [href_ "https://entrepreneurship.columbia.edu/collaboratory/"] "Collaboratory at Columbia"
      " program for their support of this course."
  where
    routeTitle :: Html ()
    routeTitle = case route of
      Route_Index -> "Multilingual Technologies and Language Diversity"
      Route_Article _ -> toHtml $ title $ getMeta val
    renderMarkdown :: Text -> Html ()
    renderMarkdown =
      Pandoc.render . Pandoc.parsePure Pandoc.readMarkdown
    formatList :: [Text] -> Html ()
    formatList = toHtml . intercalate ", " . map strip
    formatGitHub :: Maybe Text -> Html ()
    formatGitHub url = case url of
      Just u -> a_ [href_ u] "Project code repository, on GitHub"
      Nothing -> toHtml T.empty
    pageContent :: Html ()
    pageContent = case route of
      Route_Index -> do
        p_ "A course taught in the Department of Computer Science, the Data Science Institute, and the Institute for Comparative Literature and Society, Columbia University, in Spring 2020 and 2021."
        div_ $
          forM_ val $ \(r, src) ->
            li_ [class_ "pages"] $ do
              let meta = getMeta src
              a_ [href_ (Rib.routeUrl r)] $ toHtml $ title meta
              p_ $ do
                strong_ $ toHtml $ fromMaybe "" $ date meta
                toHtml $ formatList $ authors meta
              renderMarkdown `mapM_` description meta
      Route_Article _ ->
        article_ $ do
          let meta = getMeta val
          h3_ [] $ formatList $ authors meta
          formatGitHub $ github meta
          Pandoc.render val


-- | Define your site CSS here
pageStyle :: Css
pageStyle =
  C.body ? do
    -- C.margin (em 4) (pc 20) (em 1) (pc 20)
    ".header" ? do
      C.marginBottom $ em 2
    "li.pages" ? do
      C.listStyleType C.none
      C.marginTop $ em 1
      C.fontSize (em 2)
      "p" ? sym C.margin (px 0)
    "footer" ? do
      C.fontSize (em 1)
      C.marginTop $ em 2
      C.position C.absolute
      C.bottom C.none


-- | Metadata in our markdown sources
data SrcMeta = SrcMeta
  { title :: Text,
    -- | Description is optional, hence `Maybe`
    description :: Maybe Text,
    date :: Maybe Text,
    authors :: [Text],
    github :: Maybe Text
  }
  deriving (Show, Eq, Generic, FromJSON)

-- | Get metadata from Markdown's YAML block
getMeta :: Pandoc -> SrcMeta
getMeta src = case Pandoc.extractMeta src of
  Nothing -> error "No YAML metadata"
  Just (Left e) -> error $ T.unpack e
  Just (Right val) -> case fromJSON val of
    Aeson.Error e -> error $ "JSON error: " <> e
    Aeson.Success v -> v
