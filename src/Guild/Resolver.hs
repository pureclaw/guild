module Guild.Resolver
  ( resolveAgents
  , expandTilde
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>), takeFileName)

import Guild.Types

-- | Expand ~ at the start of a path to the user's home directory.
expandTilde :: FilePath -> IO FilePath
expandTilde ('~':'/':rest) = do
  home <- getHomeDirectory
  pure (home </> rest)
expandTilde ('~':rest) = do
  home <- getHomeDirectory
  pure (home </> rest)
expandTilde p = pure p

-- | Resolve all agent references from the spec.
-- For each path in agents.use, resolve relative to the library dir
-- and look for SKILL.md content.
resolveAgents :: FilePath   -- ^ base dir of the team.toml (for relative library paths)
              -> AgentsConfig
              -> IO (Either String [AgentRef])
resolveAgents baseDir ac = do
  libPath <- expandTilde (acLibrary ac)
  -- If library path is relative, resolve from baseDir
  let resolvedLib = if isAbsolute libPath
                    then libPath
                    else baseDir </> libPath
  refs <- mapM (resolveOne resolvedLib) (acUse ac)
  pure (Right refs)

-- | Resolve a single agent from the library.
resolveOne :: FilePath -> Text -> IO AgentRef
resolveOne libDir agentPath = do
  let fullPath = libDir </> T.unpack agentPath
      name     = T.pack (takeFileName (T.unpack agentPath))
  -- Try to read SKILL.md from the agent directory
  let skillPath = fullPath </> "SKILL.md"
  hasSkill <- doesFileExist skillPath
  skillContent <- if hasSkill
    then Just <$> TIO.readFile skillPath
    else pure Nothing
  pure AgentRef
    { arName    = name
    , arPath    = fullPath
    , arSkillMd = skillContent
    }

-- | Check if a path is absolute.
isAbsolute :: FilePath -> Bool
isAbsolute ('/':_) = True
isAbsolute _       = False
