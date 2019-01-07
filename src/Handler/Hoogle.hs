{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Hoogle where

import           Control.DeepSeq (NFData(..))
import           Data.Data (Data)
import qualified Data.Text as T
import           Data.Text.Read (decimal)
import qualified Hoogle
import           Import
import           Stackage.Database
import           Stackage.Database.Types (ModuleListingInfo(..))
import           Text.Blaze.Html (preEscapedToHtml)
import qualified Text.HTML.DOM
import           Text.XML.Cursor (fromDocument, ($//), content)

getHoogleDB :: SnapName -> Handler (Maybe FilePath)
getHoogleDB name = track "Handler.Hoogle.getHoogleDB" $ do
    app <- getYesod
    liftIO $ appGetHoogleDB app name

getHoogleR :: SnapName -> Handler Html
getHoogleR name = track "Handler.Hoogle.getHoogleR" $ do
    Entity _ snapshot <- lookupSnapshot name >>= maybe notFound return
    mquery <- lookupGetParam "q"
    mPackageName <- lookupGetParam "package"
    mpage <- lookupGetParam "page"
    exact <- isJust <$> lookupGetParam "exact"
    mresults' <- lookupGetParam "results"
    let count' =
            case decimal <$> mresults' of
                Just (Right (i, "")) -> min perPage i
                _ -> perPage
        page =
            case decimal <$> mpage of
                Just (Right (i, "")) -> i
                _ -> 1
        offset = (page - 1) * perPage
    mdatabasePath <- getHoogleDB name
    dbPath <- maybe (hoogleDatabaseNotAvailableFor name) return mdatabasePath

    -- Avoid concurrent Hoogle queries, see
    -- https://github.com/fpco/stackage-server/issues/172
    lock <- appHoogleLock <$> getYesod
    urlRender <- getUrlRender
    HoogleQueryOutput results mtotalCount <-
      case mquery of
        Just query -> do
            let input = HoogleQueryInput
                    { hqiQueryInput =
                        case mPackageName of
                          Nothing -> query
                          Just pn -> concat ["+", pn, " ", query]
                    , hqiLimitTo = count'
                    , hqiOffsetBy = offset
                    , hqiExact = exact
                    }

            liftIO $ withMVar lock
                   $ const
                   $ Hoogle.withDatabase dbPath
                   -- NB! I got a segfault when I didn't force with $!
                   $ \db -> return $! runHoogleQuery urlRender name db input
        Nothing -> return $ HoogleQueryOutput [] Nothing
    let queryText = fromMaybe "" mquery
        pageLink p = (SnapshotR name HoogleR
            , (if exact then (("exact", "true"):) else id)
            $ maybe id (\q' -> (("q", q'):)) mquery
              [("page", tshow p)])
        snapshotLink = SnapshotR name StackageHomeR
        hoogleForm = $(widgetFile "hoogle-form")
    defaultLayout $ do
        setTitle "Hoogle Search"
        $(widgetFile "hoogle")

getHoogleDatabaseR :: SnapName -> Handler Html
getHoogleDatabaseR name = track "Handler.Hoogle.getHoogleDatabaseR" $ do
    mdatabasePath <- getHoogleDB name
    case mdatabasePath of
        Nothing -> hoogleDatabaseNotAvailableFor name
        Just path -> sendFile "application/octet-stream" path

hoogleDatabaseNotAvailableFor :: SnapName -> Handler a
hoogleDatabaseNotAvailableFor name = track "Handler.Hoogle.hoogleDatabaseNotAvailableFor" $ do
    (>>= sendResponse) $ defaultLayout $ do
        setTitle "Hoogle database not available"
        [whamlet|
            <div .container>
                <p>The given Hoogle database is not available.
                <p>
                    <a href=@{SnapshotR name StackageHomeR}>Return to snapshot homepage
        |]

getPageCount :: Int -> Int
getPageCount totalCount = 1 + div totalCount perPage

perPage :: Int
perPage = 10

data HoogleQueryInput = HoogleQueryInput
    { hqiQueryInput  :: Text
    , hqiLimitTo     :: Int
    , hqiOffsetBy    :: Int
    , hqiExact       :: Bool
    }
    deriving (Eq, Read, Show, Data, Ord, Generic)

data HoogleQueryOutput = HoogleQueryOutput [HoogleResult] (Maybe Int) -- ^ Int == total count
    deriving (Read, Typeable, Data, Show, Eq, Generic)
instance NFData HoogleQueryOutput

data HoogleResult = HoogleResult
    { hrURL     :: String
    , hrSources :: [(PackageLink, [ModuleLink])]
    , hrTitle   :: String -- ^ HTML
    , hrBody    :: String -- ^ plain text
    }
    deriving (Eq, Read, Show, Data, Ord, Generic)

data PackageLink = PackageLink
    { plName :: String
    , plURL  :: String
    }
    deriving (Eq, Read, Show, Data, Ord, Generic)

data ModuleLink = ModuleLink
    { mlName :: ModuleNameP
    , mlURL :: String
    }
    deriving (Eq, Read, Show, Data, Ord, Generic)

instance NFData HoogleResult
instance NFData PackageLink
instance NFData ModuleLink

runHoogleQuery :: (Route App -> Text)
               -> SnapName
               -> Hoogle.Database
               -> HoogleQueryInput
               -> HoogleQueryOutput
runHoogleQuery renderUrl snapshot hoogledb HoogleQueryInput {..} =
    HoogleQueryOutput targets mcount
  where
    allTargets = Hoogle.searchDatabase hoogledb query
    targets = take (min 100 hqiLimitTo)
            $ drop hqiOffsetBy
            $ map fixResult allTargets
    query = unpack $ hqiQueryInput ++ if hqiExact then " is:exact" else ""

    mcount = limitedLength 0 allTargets

    limitedLength x [] = Just x
    limitedLength x (_:rest)
        | x >= 20 = Nothing
        | otherwise = limitedLength (x + 1) rest

    fixResult target@(Hoogle.Target {..}) = HoogleResult
        { hrURL     = case sources of
                        [(_,[ModuleLink _ m])] -> m ++ haddockAnchorFromUrl targetURL
                        _ -> fromMaybe targetURL $ asum
                                [ moduleLink
                                , packageLink
                                ]
        , hrSources = sources
        , hrTitle   = -- FIXME find out why these replaces are necessary
                      unpack $ T.replace "<0>" "" $ T.replace "</0>" "" $ pack
                      targetItem
        , hrBody    = targetDocs
        }
      where sources = toList $ do
              (packageLink', mname, mkModuleLink) <- targetLinks renderUrl snapshot target
              Just (packageLink', [ModuleLink mname $ mkModuleLink mname])

            moduleLink = do
              (_packageLink, mname, mkModuleLink) <- targetLinks renderUrl snapshot target
              guard (mname == "module")
              let doc = Text.HTML.DOM.parseLBS $ encodeUtf8 $ pack targetItem
                  cursor = fromDocument doc
                  item = T.concat $ cursor $// content
              mkModuleLink . fromString . T.unpack <$> T.stripPrefix "module " item

            packageLink = do
              guard (isNothing targetPackage)
              "package" <- Just targetType
              let doc = Text.HTML.DOM.parseLBS $ encodeUtf8 $ pack targetItem
                  cursor = fromDocument doc
                  item = T.concat $ cursor $// content
              pnameTxt <- T.stripPrefix "package " item
              pname <- fromPathPiece pnameTxt
              return $ T.unpack $ renderUrl $ SnapshotR snapshot $ StackageSdistR $ PNVName pname

            haddockAnchorFromUrl =
                ('#':) . reverse . takeWhile (/='#') . reverse

targetLinks ::
       (Route App -> Text)
    -> SnapName
    -> Hoogle.Target
    -> Maybe (PackageLink, ModuleNameP, ModuleNameP -> String)
targetLinks renderUrl sname Hoogle.Target {..} = do
    (pname, _) <- targetPackage
    (mname, _) <- targetModule
    packageIdentifierP <- fromPathPiece $ T.pack pname
    let mkMli modName = ModuleListingInfo modName packageIdentifierP
        packageLink = PackageLink pname (makePackageLink pname)
        mkModuleLink modName = T.unpack (renderUrl (haddockUrl sname (mkMli modName)))
    return (packageLink, fromString mname, mkModuleLink)

makePackageLink :: String -> String
makePackageLink pkg = "/package/" ++ pkg
