{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}

module Aria.Repo
  ( newRacer
  , deleteRacer
  , getScriptLogs
  , uploadCode
  , selectBuild
  , startRace
  , stopRace
  , AS.scriptBasePath
  , AS.scriptStartTime
  , AS.scriptEndTime
  , AS.scriptFile
  , AS.scriptArgs
  , AS.stdErr
  , AS.stdOut
  , AS.exitCode
  , RepoAppState(..)
  , RepoApp(..)
  , RepoDB
  , RepoDBState(..)
  , RacerNotFound(..)
  ) where

import Aria.Repo.DB
import Aria.Types
import Control.Lens
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.State
import Data.Time (getCurrentTime)
import Data.Acid
import Data.Acid.Advanced
import Data.Data
import Data.Text (Text)
import Data.Monoid ((<>))
import System.FilePath ((</>))
import Data.Char (isSpace)
import qualified Aria.Scripts as AS
import qualified Data.List as DL

type RepoAppState = AcidState RepoDBState

type RepoApp = StateT RepoAppState

data RacerNotFound =
  RacerNotFound RacerId
  deriving (Eq, Ord, Show, Read, Data, Typeable)

instance Exception RacerNotFound

newRacer
  :: (Monad m, MonadCatch m, MonadIO m, MonadThrow m)
  => Racer -> RepoApp m RacerId
newRacer racer =
  do acid <- get
     rid <- update' acid (InsertRacer racer)
     runScript (AS.CreateRacer rid)
     return rid 
  `catchAll`
  (\_ -> undoNewUser >> (return $ RacerId 0))

undoNewUser
  :: (Monad m, MonadIO m, MonadThrow m)
  => RepoApp m ()
undoNewUser = do
  acid <- get
  (RacerId rid) <- query' acid (GetNextRacerId)
  update' acid (RemoveRacer . RacerId $ rid - 1)

deleteRacer
  :: (MonadIO m, MonadThrow m)
  => RacerId -> RepoApp m ()
deleteRacer rid = do
  acid <- get
  update' acid (RemoveRacer rid)
  runScript (AS.RemoveRacer rid)
  return ()

uploadCode
  :: (MonadIO m, MonadThrow m)
  => RacerId -> FilePath -> Text -> RepoApp m ()
uploadCode rid file bName =
  withRacer rid $
  \racer -> do
    acid <- get
    bPath <- AS._scriptCwd <$> query' acid (GetScriptConfig)
    let outFile = bPath ++ "/racer_" ++ (show $ _unRacerId rid) ++ "_commit.out"
    runScripts $
      [ (AS.UploadCode rid file)
      , (AS.BuildRacer rid "")
      , (AS.CommitBuild rid bName outFile)
      ]
    bRev <- liftIO $ DL.takeWhile (not . isSpace) <$> readFile outFile
    dt <- liftIO $ getCurrentTime
    let newBuild =
          RacerBuild
          { _buildName = bName
          , _buildRev = bRev
          , _buildDate = dt
          }
    update' acid . UpdateRacer $
      (racer & selectedBuild .~ 0 & racerBuilds %~ (newBuild :))
    return ()

withRacer
  :: (Monad m, MonadIO m, MonadThrow m)
  => RacerId -> (Racer -> RepoApp m ()) -> RepoApp m ()
withRacer rid act = do
  acid <- get
  racer <- query' acid $ GetRacerById rid
  case racer of
    Nothing -> throwM $ RacerNotFound rid
    Just r -> act r

getScriptLogs
  :: (MonadIO m, Monad m)
  => RepoApp m AS.ScriptLog
getScriptLogs = get >>= \acid -> query' acid GetScriptLog

selectBuild
  :: (MonadIO m, Monad m, MonadThrow m)
  => RacerId -> SHA -> RepoApp m ()
selectBuild rid sha = do
  acid <- get
  withRacer rid $
    \racer -> do
      runScript $ AS.BuildRacer rid sha
      update'
        acid
        (UpdateRacer $
         racer & selectedBuild .~ setSelBuild (racer ^. racerBuilds))
      return ()
  where
    setSelBuild = maybe 0 toInteger . DL.findIndex ((== sha) . _buildRev)

startRace :: (MonadIO m, MonadThrow m, Monad m) => RaceData -> RepoApp m ()
startRace (RaceData (r1,r2)) = do 
  acid <- get
  raceFlag <- query' acid $ GetRunRaceFlag
  update' acid $ SetRunRaceFlag True
  unless raceFlag $ (runScript (AS.StartRace [r1,r2]) >> return ())
  return ()

stopRace :: (MonadIO m, MonadThrow m, Monad m) => [Integer] -> RepoApp m ()
stopRace [] = return ()
stopRace lns = do 
  acid <- get
  update' acid $ SetRunRaceFlag False
  runScript . AS.StopRace $ lns 
  return ()

runScript
  :: (MonadIO m, MonadThrow m, AS.Script a)
  => a -> RepoApp m [String]
runScript = runScripts . Identity

-- | Run the given script command. Upon an ExitFailure throw a ScriptError exception
runScripts
  :: (MonadIO m, MonadThrow m, AS.Script a, Traversable t)
  => t a -> RepoApp m [String]
runScripts cmds = do
  acid <- get
  config <- query' acid GetScriptConfig
  log <- AS.runScriptCommand config cmds
  update' acid (AddScriptLog log)
  return $ AS._stdOut <$> log
