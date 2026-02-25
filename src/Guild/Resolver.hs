module Guild.Resolver
  ( resolveAgents
  , expandTilde
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))

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

-- | Collect all unique agent names referenced in the pipeline phases.
agentNamesFromPhases :: [Phase] -> [Text]
agentNamesFromPhases phases = nub $ concatMap phaseAgents phases
  where
    phaseAgents ph =
      maybe [] (:[]) (phAgent ph) ++ maybe [] id (phAgents ph)

-- | Resolve all agents referenced in the pipeline from the agents_dir.
-- Agent dirs are resolved as: <agents_dir>/<agent_name>/
resolveAgents :: FilePath   -- ^ base dir of the team.toml (for relative agents_dir paths)
              -> FilePath   -- ^ agents_dir from the spec (may be relative or ~/...)
              -> [Phase]
              -> IO (Either String [AgentRef])
resolveAgents baseDir agentsDir phases = do
  expanded <- expandTilde agentsDir
  let resolvedDir = if isAbsolute expanded
                    then expanded
                    else baseDir </> expanded
  let names = agentNamesFromPhases phases
  refs <- mapM (resolveOne resolvedDir) names
  pure (Right refs)

-- | Resolve a single agent by name from the agents directory.
resolveOne :: FilePath -> Text -> IO AgentRef
resolveOne agentsDir name = do
  let agentPath = agentsDir </> T.unpack name
  let skillPath = agentPath </> "SKILL.md"
  hasSkill <- doesFileExist skillPath
  skillContent <- if hasSkill
    then Just <$> TIO.readFile skillPath
    else pure Nothing
  pure AgentRef
    { arName    = name
    , arPath    = agentPath
    , arSkillMd = skillContent
    }

-- | Check if a path is absolute.
isAbsolute :: FilePath -> Bool
isAbsolute ('/':_) = True
isAbsolute _       = False
