{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           BasePrelude hiding (take, (&), (\\))
import           Control.Lens hiding ((<.>))
import           Control.Monad.Except
import           Data.Aeson.Lens
import           Data.Attoparsec.Text hiding (try)
import           Data.Text.Strict.Lens
import           Network.Linklater hiding (Command)
import           Rendering

import           Data.Set ((\\), Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Network.Linklater as Linklater
import           Network.Wai.Handler.Warp as Warp
import qualified Network.Wreq as Wreq
import           System.Directory (getDirectoryContents, createDirectoryIfMissing)
import           System.FilePath (dropExtension, (<.>), (</>))

data Command = ListMemes | MakeMeme Meme | AmbiguousSide
instance Show Command where
  show ListMemes = "list"
  show (MakeMeme (Meme a b c)) = show [a, Text.unpack b, Text.unpack c]
  show AmbiguousSide = "ambiguous"

inputParser :: Parser Command
inputParser = parseNothing
  <|> parseComplete
  <|> parseNoText
  <|> parseIncomplete
  where parseNothing = endOfInput *> return ListMemes
        parseNoText = (\t -> MakeMeme (Meme t "" "")) <$> parseTemplate <* endOfInput
        parseTemplate = Text.unpack . Text.toLower <$> takeTill isSpace
        parseComplete = do
          templateName <- parseTemplate
          topText <- takeTill (== ';')
          _ <- take 1
          bottomText <- takeText
          return $ MakeMeme $ Meme templateName
                                   (Text.toUpper $ Text.strip topText)
                                   (Text.toUpper $ Text.strip bottomText)
        parseIncomplete = return AmbiguousSide

usageMessage :: Set String -> Text
usageMessage memes =
  Text.intercalate "\n" [ "Usage: /meme memename (top text); (bottom text)"
                        , "That's a semicolon character separating the top from the bottom. You can't make a meme with a semicolon in the top text. Deal with it."
                        , "See https://github.com/ianthehenry/memegen/tree/master/templates for a complete list of memes, and open a pull request to add your own. Or try to figure out what it might be from this list:"
                        , ""
                        , Text.intercalate " " (Set.toAscList (Set.map Text.pack memes))
                        ]

saveMeme :: String -> Meme -> IO FilePath
saveMeme localPath meme = do
  filename <- (<.> "png") . UUID.toString <$> UUID.nextRandom
  renderMeme meme (localPath </> filename)
  return filename

cleverlyReadFile :: FilePath -> IO Text
cleverlyReadFile filename =
  readFile filename <&> (^. (packed . to Text.strip))

upload :: FilePath -> IO (Maybe Text)
upload src = do
  let params = Wreq.partFileSource "image" src
  let opts = Wreq.defaults & Wreq.header "Authorization" .~ ["Client-ID " <> imgurID]
  response <- Wreq.postWith opts "https://api.imgur.com/3/image" params
  return (response ^? (Wreq.responseBody . key "data" . key "link" . _String))
  where
    imgurID = "cf41a92dd376e2f"

bot :: (MonadError String m, MonadIO m) => Config -> Linklater.Command -> m Text
bot config (Linklater.Command "meme" (User username) channel (Just query)) = do
  templates <- liftIO templatesIO
  case parseOnly inputParser (Text.strip query) of
    Left _ -> return (usageMessage templates)
    Right ListMemes -> return (usageMessage templates)
    Right AmbiguousSide -> return "You gotta put the semicolon somewhere! Otherwise it's ambiguous if it should go on the top or bottom. NO it is not meme-aware get over yourself"
    Right (MakeMeme meme@(Meme templateName _ _))
      | templateName `Set.member` templates -> do
        let pathPrefix = Text.unpack username
        filename <- liftIO $ do
          let dir = "/tmp/memegen" </> pathPrefix
          createDirectoryIfMissing True dir
          saveMeme dir meme
        void . liftIO . forkIO $ do
          urlM <- liftIO (try $ upload ("/tmp/memegen" </> pathPrefix </> filename))
          case urlM of
            Right (Just url) -> do
              let formats = [FormatLink url ""]
              either <- runExceptT $ say (FormattedMessage (EmojiIcon "helicopter") "memebot" channel formats) config
              case either of
                Right _ -> return ()
                Left e -> print ("say error: " <> show e)
            Left (e :: SomeException) -> do
              print e
            _ ->
              return ()
        return "one .... sec ......"
      | otherwise -> return $ Text.append "Unknown template " (Text.pack templateName)

bot _ _ =
  throwError "unrecognized command"

templatesIO :: IO (Set String)
templatesIO = do
  files <- getDirectoryContents "templates/"
  let f = Set.fromList files \\ Set.fromList [".", ".."]
  let t = Set.map dropExtension f
  return t

main :: IO ()
main = do
  port <- (^. unpacked) <$> cleverlyReadFile "memegen.port"
  hook <- (Config <$> cleverlyReadFile "memegen.hook")
  putStrLn ("Running on port " <> port)
  Warp.run (read port) (slashSimple $ foo hook)
  where
    foo hook command = handle (\(e :: SomeException) -> print e >> return "oh dear something bad happened") $ do
      result <- runExceptT (bot hook command)
      return (either gussy id result)
      where
        gussy t = ("error: " <> t) ^. packed
