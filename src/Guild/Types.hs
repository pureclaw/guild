{-# LANGUAGE OverloadedStrings #-}

module Guild.Types
  ( TeamSpec(..)
  , ProjectConfig(..)
  , Phase(..)
  , Gate(..)
  , Checkpoint(..)
  , BuildConfig(..)
  , AgentRef(..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Toml.Schema

-- | Top-level parsed TOML team spec.
data TeamSpec = TeamSpec
  { tsProject     :: ProjectConfig
  , tsAgentsDir   :: FilePath        -- ^ path to agent library on disk
  , tsPhases      :: [Phase]
  , tsGates       :: [Gate]
  , tsCheckpoints :: [Checkpoint]
  , tsBuild       :: Maybe BuildConfig
  } deriving (Show)

data ProjectConfig = ProjectConfig
  { pcName        :: Text
  , pcDescription :: Text
  } deriving (Show)

-- | A pipeline phase. Either single-agent or multi-agent.
data Phase = Phase
  { phName          :: Text
  , phAgent         :: Maybe Text       -- single agent
  , phAgents        :: Maybe [Text]     -- multi-agent (parallel)
  , phRequire       :: Maybe Text       -- aggregation requirement
  , phFreshInstance  :: Maybe Bool
  } deriving (Show)

-- | A gate definition.
data Gate = Gate
  { gName    :: Text
  , gType    :: Text        -- "shell" | "predicate"
  , gCommand :: Maybe Text  -- for shell gates
  , gExpr    :: Maybe Text  -- for predicate gates
  } deriving (Show)

-- | A human checkpoint — pipeline pauses after this phase.
data Checkpoint = Checkpoint
  { cpAfter       :: Text
  , cpDescription :: Text
  } deriving (Show)

-- | Build configuration section.
data BuildConfig = BuildConfig
  { bcTest              :: Maybe Text
  , bcLint              :: Maybe Text
  , bcTypecheck         :: Maybe Text
  , bcCoverage          :: Maybe Text
  , bcCoverageThreshold :: Maybe Int
  } deriving (Show)

-- | A resolved agent reference with its filesystem path.
data AgentRef = AgentRef
  { arName    :: Text
  , arPath    :: FilePath
  , arSkillMd :: Maybe Text   -- contents of SKILL.md if found
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- FromValue instances (TOML decoding)
-- ---------------------------------------------------------------------------

instance FromValue TeamSpec where
  fromValue = parseTableFromValue $ do
    project     <- reqKey "project"
    agentsDir   <- reqKey "agents_dir"
    phases      <- reqKeyOf "phases" (listOf (\_ v -> fromValue v))
    gates       <- optKeyOf "gates" (listOf (\_ v -> fromValue v))
    checkpoints <- optKeyOf "checkpoints" (listOf (\_ v -> fromValue v))
    build       <- optKey "build"
    pure TeamSpec
      { tsProject     = project
      , tsAgentsDir   = T.unpack agentsDir
      , tsPhases      = phases
      , tsGates       = maybe [] id gates
      , tsCheckpoints = maybe [] id checkpoints
      , tsBuild       = build
      }

instance FromValue ProjectConfig where
  fromValue = parseTableFromValue $ do
    name <- reqKey "name"
    desc <- reqKey "description"
    pure ProjectConfig
      { pcName = name
      , pcDescription = desc
      }

instance FromValue Phase where
  fromValue = parseTableFromValue $ do
    name    <- reqKey "name"
    agent   <- optKey "agent"
    agents  <- optKeyOf "agents" (listOf (\_ v -> fromValue v))
    req     <- optKey "require"
    fresh   <- optKey "fresh_instance"
    pure Phase
      { phName         = name
      , phAgent        = agent
      , phAgents       = agents
      , phRequire      = req
      , phFreshInstance = fresh
      }

instance FromValue Gate where
  fromValue = parseTableFromValue $ do
    name <- reqKey "name"
    typ  <- reqKey "type"
    cmd  <- optKey "command"
    expr <- optKey "expr"
    pure Gate
      { gName    = name
      , gType    = typ
      , gCommand = cmd
      , gExpr    = expr
      }

instance FromValue Checkpoint where
  fromValue = parseTableFromValue $ do
    after <- reqKey "after"
    desc  <- reqKey "description"
    pure Checkpoint
      { cpAfter       = after
      , cpDescription = desc
      }

instance FromValue BuildConfig where
  fromValue = parseTableFromValue $ do
    test     <- optKey "test"
    lint     <- optKey "lint"
    tc       <- optKey "typecheck"
    cov      <- optKey "coverage"
    thresh   <- optKey "coverage_threshold"
    pure BuildConfig
      { bcTest              = test
      , bcLint              = lint
      , bcTypecheck         = tc
      , bcCoverage          = cov
      , bcCoverageThreshold = thresh
      }
