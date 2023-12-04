{-# LANGUAGE DerivingStrategies, StandaloneDeriving, UndecidableInstances, DataKinds, FlexibleInstances, TemplateHaskell, InstanceSigs #-}


import qualified Prelude as P ()
import ClassyPrelude.Yesod
import Yesod.JobQueueSeq
import qualified Yesod.JobQueue.Routes as JR
import Yesod.JobQueue.Scheduler
import Database.Persist.Sqlite
import Control.Monad.Logger (runStderrLoggingT)
import Control.Concurrent (threadDelay)


-- Yesod Persist settings (Nothing special here)
share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Person
  name String
  age Int
  deriving Show
|]
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB action = do
        app <- getYesod
        runSqlPool action $ appConnPool app


-- Make Yesod App that have ConnectionPool, JobState
data App = App {
      appConnPool :: ConnectionPool
    , appDBConf   :: SqliteConf
    , appJobState :: JobState
    , appJobQ     :: JobQ
    }

mkYesod "App" [parseRoutes|
/ HomeR GET
/job JobQueueR JobQueue getJobQueue -- ^ JobQueue API and Manager
|]

instance Yesod App where
    --defaultLayout :: WidgetFor site () -> HandlerFor site Html
    defaultLayout :: Widget -> Handler Html
    defaultLayout w = do
        p <- widgetToPageContent w
        msgs <- getMessages
        withUrlRenderer [hamlet|
            $newline never
            $doctype 5
            <html>
                <head>
                    <title>#{pageTitle p}
                    $maybe description <- pageDescription p
                      <meta name="description" content="#{description}">
                    ^{pageHead p}
                    <link rel="stylesheet" href="//cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/css/bootstrap.min.css">
                    <script src="//unpkg.com/htmx.org@1.6.1">
                <body>
                    $forall (status, msg) <- msgs
                        <p class="message #{status}">#{msg}
                    ^{pageBody p}
            |]

-- JobQueue settings
data MyJobType = AggregationUser
               | PushNotification
               | HelloJob String
               deriving (Show, Read, Generic)

instance YesodJobQueue App where
    type JobType App = MyJobType
    getJobState = appJobState
    getQ = appJobQ
    threadNumber _ = 2
    runDBJob action = do
        app <- ask
        runSqlPool action $ appConnPool app
    runJob m jid AggregationUser = do
        us <- runDBJob $ selectList ([] :: [Filter Person]) []
        logJobState m 0 jid "hello state"
        liftIO $ threadDelay $ 10 * 1000 * 1000
        print us
        putStrLn "complate job!"
    runJob _ _ PushNotification = do
        putStrLn "sent notification!"
    runJob _ _ (HelloJob name) = do
        putStrLn . pack $ "Hello " ++ name
    --getClassInformation app = [jobQueueInfo app, schedulerInfo app]
    getClassInformation app = [jobQueueInfo app]
    describeJob _ "AggregationUser" = Just "aggregate user's activities"
    describeJob _ _ = Nothing

{-
instance YesodJobQueueScheduler App  where
    getJobSchedules _ = [("* * * * *", AggregationUser)
                         , ("* * * * *", HelloJob "Foo")]
-}

-- Handlers
getHomeR :: HandlerT App IO Html
getHomeR = defaultLayout $ do
    setTitle "JobQueue sample"
    -- addStylesheetRemote "//cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/css/bootstrap.min.css"
    -- addScriptRemote "//unpkg.com/htmx.org@1.6.1"
    [whamlet|
        <h1>Hello
        <a href="@{JobQueueR JR.JobManagerR}">Job Manager
    |]

-- Main
main :: IO ()
main = runStderrLoggingT $
       withSqlitePool (sqlDatabase dbConf) (sqlPoolSize dbConf) $ \pool -> liftIO $ do
           runResourceT $ flip runSqlPool pool $ do
               runMigration migrateAll
               insert $ Person "test" 28
           jobState <- newJobState -- ^ create JobState
           jobQueue <- newJobQueue -- ^ create JobQ
           let app = App pool dbConf jobState jobQueue
           startDequeue app
           startDequeue app
           startJobSchedule app
           warp 3000 app
  where dbConf = SqliteConf "test.db3" 4
