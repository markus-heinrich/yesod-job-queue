{-# OPTIONS_HADDOCK prune #-}
{-# LANGUAGE TemplateHaskell #-}

module Yesod.JobQueue.Types where

import Data.Aeson.APIFieldJsonTH
import Data.Text (Text)

data PostJobQueueRequest = PostJobQueueRequest {
    _postJobQueueRequestJob :: String
} deriving (Show)

deriveApiFieldJSON ''PostJobQueueRequest



data JobQueueClassInfo = JobQueueClassInfo {
    _jobQueueClassInfoClassName :: Text
    , _jobQueueClassInfoValues :: [Text]
    } deriving (Show)

deriveApiFieldJSON ''JobQueueClassInfo
