{-# LANGUAGE OverloadedStrings #-}

module Guild.Runtime.Types
  ( RunStatus(..)
  , RunRecord(..)
  , StepRecord(..)
  , SlotEntry(..)
  ) where

import Data.Text (Text)

-- | Status of a pipeline run or individual step.
data RunStatus
  = Pending
  | Running
  | Success
  | Failed
  | Skipped
  deriving (Show, Eq)

-- | Record of a full pipeline run.
data RunRecord = RunRecord
  { rrId        :: Text      -- ^ UUID as text
  , rrSpecPath  :: FilePath
  , rrStartTime :: Text      -- ^ ISO 8601 timestamp
  , rrStatus    :: RunStatus
  } deriving (Show)

-- | Record of a single step within a run.
data StepRecord = StepRecord
  { srName   :: Text
  , srAgent  :: Text
  , srStatus :: RunStatus
  , srOutput :: Text
  } deriving (Show)

-- | A single entry in the named slot store.
data SlotEntry = SlotEntry
  { seStep  :: Text
  , seKey   :: Text
  , seValue :: Text
  } deriving (Show)
