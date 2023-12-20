{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
--
-- Background jobs library for Yesod.
-- Use example is in README.md.
--
module Yesod.JobQueueSeq (
    YesodJobQueue (..)
    , JobId
    -- maybe also
    -- , module Data.UUID
    , JobQueue
    , startDequeue
    , enqueue
    , JobState
    , JobQ
    , newJobState
    , newJobQueue
    , jobQueueInfo
    , getJobQueue
    , RunningJob (..)
    ) where

import Yesod.JobQueue.GenericConstr
import Yesod.JobQueue.Routes
import Yesod.JobQueue.Types

import Control.Concurrent (forkIO)
import qualified Control.Concurrent.STM as STM
import Control.Concurrent.STM (TVar)
import Control.Exception (throwIO)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Data.Aeson (Value, (.=), object)
import Data.Aeson.TH (defaultOptions, deriveToJSON)
import Data.ByteString (ByteString)
import Data.Foldable
import qualified Data.List as L
import Data.Proxy (Proxy(Proxy))
import Data.Sequence((<|), ViewL( (:<) ) )
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.UUID as U
import qualified Data.UUID.V4 as U
import GHC.Generics (Generic, Rep)
import Text.Read (readMaybe)
import Yesod.Core
    (HandlerFor, SubHandlerFor, Html, Yesod, YesodSubDispatch(yesodSubDispatch), getYesod,
     hamlet, whamlet, invalidArgs, mkYesodSubDispatch, notFound, requireCheckJsonBody,
     returnJson, sendResponse, toContent, withUrlRenderer, liftHandler, defaultLayout,
     toWidget, addScriptRemote, addStylesheetRemote, setTitle, MonadLogger, makeLogger, logInfo, MonadHandler,
     getRouteToParent, PathPiece, PathPiece(..))
import Yesod.Core.Types (HandlerContents(HCError), ErrorResponse(InternalError), Logger)

import Yesod.Persist.Core (YesodPersistBackend, YesodDB)

-- | Thread ID for convenience
type ThreadNum = Int

-- | JobType String
type JobTypeString = String

-- | JobId
type JobId = U.UUID

instance PathPiece JobId where
    toPathPiece   = U.toText
    fromPathPiece = U.fromText

-- | Information of the running job
data RunningJob = RunningJob {
      jobType :: JobTypeString
    , threadId :: ThreadNum
    , jobId :: JobId
    , startTime :: UTCTime
    } deriving (Eq, Show)

$(deriveToJSON defaultOptions ''RunningJob)

data JobQueueItem = JobQueueItem {
      queueJobType :: JobTypeString
    , queueTime    :: UTCTime
    , queueJobId   :: JobId
} deriving (Show, Read)
$(deriveToJSON defaultOptions ''JobQueueItem)

-- | Manage the running jobs
type JobState = TVar [RunningJob]
type JobQ = TVar (Seq.Seq JobQueueItem)

-- | create new JobState
newJobState :: IO (TVar [RunningJob])
newJobState = STM.newTVarIO []

newJobQueue :: IO (TVar (Seq.Seq JobQueueItem))
newJobQueue = STM.newTVarIO Seq.empty

-- | Backend jobs for Yesod
class (Yesod master, Read (JobType master), Show (JobType master)
      , Generic (JobType master), Constructors (Rep (JobType master))
      -- , Backend q
      )
      => YesodJobQueue master where

    -- | Custom Job Type
    type JobType master

    -- | Job Handler
    runJob :: MonadUnliftIO m
              => master -> JobId -> JobType master -> ReaderT master m ()

    -- | get job queue
    getQ :: master -> JobQ

    -- | The number of threads to run the job
    threadNumber :: master -> Int
    threadNumber _ = 1

    -- | runDB for job
    runDBJob :: MonadUnliftIO m
                => ReaderT (YesodPersistBackend master) (ReaderT master m) a
                -- => YesodDB master m
                -> ReaderT master m a

    -- | get job state
    getJobState :: master -> JobState

    getJobStateS :: master -> JobId -> IO (Maybe RunningJob)
    getJobStateS master jid = do
        let s = getJobState master
        items <- STM.atomically (STM.readTVar s)
        return $ find (\x -> jobId x == jid) items

    -- | Job Information
    describeJob :: master -> JobTypeString -> Maybe Text
    describeJob _ _ = Nothing

    -- | get information of all type classes related job-queue
    getClassInformation :: master -> [JobQueueClassInfo]
    getClassInformation m = [jobQueueInfo m]

    -- | flush queue on startup
    flushQueueOnStartup :: master -> Bool
    flushQueueOnStartup _ = False

startDequeue :: (YesodJobQueue master, MonadUnliftIO m) => master -> m ()
startDequeue m = do
    -- start threads
    let num = threadNumber m
    forM_ [1 .. num] $ startThread m

-- | start dequeue-ing job in new thread
startThread :: forall master m . (YesodJobQueue master, MonadUnliftIO m)
            => master -> ThreadNum -> m ()
startThread m tNo = void $ liftIO $ forkIO $ do
    forever $ do
        item <- STM.atomically $ do
            items <- STM.readTVar (getQ m)
            case Seq.viewl items of
                Seq.EmptyL   -> STM.retry
                item :< rest -> STM.writeTVar (getQ m) rest >> return item
        let jt = queueJobType item
        handleJob item $ readJobType m jt
  where
    handleJob :: JobQueueItem -> Maybe (JobType master) -> IO ()
    handleJob _ Nothing = putStrLn $ "[dequeue-" ++ show tNo ++ "] unknown JobType"
    handleJob item (Just jt) = do
        let jid = queueJobId item
        time <- getCurrentTime
        let runningJob = RunningJob
                { jobType = show jt
                , threadId = tNo
                , jobId = jid
                , startTime = time
                }
        STM.atomically $ STM.modifyTVar (getJobState m) (runningJob:)
        runReaderT (runJob m jid jt) m
        STM.atomically $ STM.modifyTVar (getJobState m) (L.delete runningJob)

-- | Add job to end of the queue
enqueue :: (MonadIO m, YesodJobQueue master) => master -> JobType master -> m JobId
enqueue m jt = liftIO $ do
    time <- getCurrentTime
    uid <- U.nextRandom
    let item = JobQueueItem
            { queueJobType = show jt
            , queueTime = time
            , queueJobId = uid
            }
    STM.atomically $ STM.modifyTVar (getQ m) (item <|)
    return uid

-- | Get all jobs in the queue
listQueue :: YesodJobQueue master => master -> IO [JobQueueItem]
listQueue m = STM.atomically $ STM.readTVar (getQ m) >>= return . toList

-- | read JobType from String
readJobType :: YesodJobQueue master => master -> String -> Maybe (JobType master)
readJobType _ = readMaybe

-- | Need by 'getClassInformation'
jobQueueInfo :: YesodJobQueue master => master ->  JobQueueClassInfo
jobQueueInfo m = JobQueueClassInfo "JobQueue" [threadInfo]
  where threadInfo = "Number of threads: " `T.append` (T.pack . show $ threadNumber m)

-- | Handler for job manager api routes
-- type JobHandler master a =
--     YesodJobQueue master => HandlerFor JobQueue a
type JobHandler master a =
  YesodJobQueue master => SubHandlerFor JobQueue master a

jobTypeProxy :: (YesodJobQueue m) => m -> Proxy (JobType m)
jobTypeProxy _ = Proxy

-- | get job definitions
getJobR :: JobHandler master Html
getJobR = do
    toMaster <- getRouteToParent
    liftHandler $ do
        y <- getYesod
        let parseConstr (c:args) = object ["type" .= c, "args" .= args, "description" .= describeJob y c]
            constrs = map parseConstr $ genericConstructors $ jobTypeProxy y
        let parseConstr2 (c:args) = (c, args, describeJob y c)
            constrs2 = map parseConstr2 $ genericConstructors $ jobTypeProxy y
        let info = getClassInformation y
        withUrlRenderer [hamlet|
            <h3>Job Types
            <!--#{show constrs}-->
            <table .table.table-striped>
              <thead>
                <tr>
                  <th>Name
                  <th>Description
                  <th>Action
              <tbody>
                $forall co <- constrs2
                  <tr>
                    $with (c, a, mdesc) <- co
                      <td>#{c}
                      <td>
                        $maybe desc <- mdesc
                          #{desc}
                      <td>
                        $if null a
                          <!-- <button hx-post="@{toMaster JobQueueR}" hx-vals="{ 'job': '#{c}' }" .btn.btn-info>Enqueue -->
                          <button hx-post="@{toMaster $ JobEnqueueR c}" .btn.btn-info>Enqueue
                        $else
                          Args: 
                          $forall aelem <- a
                            #{aelem}, 


            <h3>Settings
            <!--#{show info}-->
            <table .table.table-striped>
              <thead>
                <tr>
                  <th>Class
                  <th>Information
              <tbody>
                $forall i <- info
                  <tr>
                    <td>#{_jobQueueClassInfoClassName i}
                    <td>
                      $forall v <- _jobQueueClassInfoValues i
                        #{v}<br />
        |]


-- | get a list of jobs in queue
getJobQueueR :: JobHandler master Html
getJobQueueR = liftHandler $ do
    y <- getYesod
    q <- liftIO $ listQueue y
    withUrlRenderer [hamlet|
        <h3>Queue
        <table .table.table-striped>
          <thead>
            <tr>
              <th>Type
              <th>Enqueued at
          <tbody>
            $forall job <- q
              <tr>
                <td>#{queueJobType job}
                <td>#{show $ queueTime job}
        |]

-- | enqueue new job
postJobQueueR :: JobHandler master Value
postJobQueueR = liftHandler $ do
    y <- getYesod
    body <- requireCheckJsonBody :: HandlerFor master PostJobQueueRequest
    case readJobType y (_postJobQueueRequestJob body) of
     Just jt -> do
         liftIO $ void $ enqueue y jt
         returnJson $ object []
     Nothing -> invalidArgs ["job"]

postJobEnqueueR :: String -> JobHandler master Html
postJobEnqueueR job = liftHandler $ do
    y <- getYesod
    case readJobType y job of
        Just jt -> do
            liftIO $ void $ enqueue y jt
            -- returnJson $ object []
            withUrlRenderer [hamlet| success
            |]
        Nothing -> -- invalidArgs ["job"]
            withUrlRenderer [hamlet| error
            |]

-- | get a list of running jobs
getJobStateR :: JobHandler master Html
getJobStateR = liftHandler $ do
    y <- getYesod
    s <- liftIO $ STM.readTVarIO (getJobState y)
    withUrlRenderer [hamlet|
        <h3>Running Jobs
        <table .table.table-striped>
          <thead>
            <tr>
              <th>Type
              <th>Thread ID
              <th>Job ID
              <th>Start at
          <tbody>
            $forall job <- s
              <tr>
                <td>#{jobType job}
                <td>#{threadId job}
                <td>#{show $ jobId job}
                <td>#{show $ startTime job}
        |]

getJobManagerR :: JobHandler master Html
getJobManagerR = do
    toMaster <- getRouteToParent
    liftHandler $ do
      y <- getYesod
      defaultLayout $ do
          setTitle "YesodJobQueue Manager"
          toWidget [whamlet|
          <div id="job-types-and-settings" hx-get="@{toMaster JobR}" hx-trigger="load">

          <div id="job-queue" hx-get="@{toMaster JobQueueR}" hx-trigger="load, every 5s">

          <div id="job-running" hx-get="@{toMaster JobStateR}" hx-trigger="load, every 5s">
          |]

-- | JobQueue manager subsite
instance YesodJobQueue master => YesodSubDispatch JobQueue master where
    yesodSubDispatch = $(mkYesodSubDispatch resourcesJobQueue)

getJobQueue :: a -> JobQueue
getJobQueue = const JobQueue
