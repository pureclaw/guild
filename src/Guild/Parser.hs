module Guild.Parser
  ( parseTeamSpec
  ) where

import qualified Data.Text.IO as TIO
import Toml (decode)
import Toml.Schema (Result(..))

import Guild.Types

-- | Parse a TOML team spec file from disk.
parseTeamSpec :: FilePath -> IO (Either String TeamSpec)
parseTeamSpec path = do
  contents <- TIO.readFile path
  case decode contents of
    Success _warnings spec -> pure (Right spec)
    Failure errs           -> pure (Left (unlines errs))
