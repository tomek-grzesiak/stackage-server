{-# LANGUAGE PartialTypeSignatures #-}
module Stackage.Snapshot.Diff
  ( getSnapshotDiff
  , snapshotDiff
  , SnapshotDiff
  , VersionChange(..)
  ) where

import qualified Data.HashMap.Strict as HashMap
import           Data.Align
import           Control.Arrow
import           ClassyPrelude
import           Data.These
import           Stackage.Database (SnapshotId, PackageListingInfo(..),
                                    GetStackageDatabase, getPackages)
type PackageName = Text
type Version = Text

type SnapshotDiff = HashMap PackageName VersionChange

-- | Versions of a package as it occurs in the listings provided to `snapshotDiff`.
--
--   Would be represented with `These v1 v2` if the package is present in both listings,
--   otherwise it would be `This v1` if the package is present only in the first listing,
--   or `That v2` if only in the second.
newtype VersionChange = VersionChange { unVersionChange :: These Version Version }

changed :: VersionChange -> Bool
changed = these (const True) (const True) (/=) . unVersionChange

getSnapshotDiff :: GetStackageDatabase m => SnapshotId -> SnapshotId -> m SnapshotDiff
getSnapshotDiff a b = snapshotDiff <$> getPackages a <*> getPackages b

snapshotDiff :: [PackageListingInfo] -> [PackageListingInfo] -> SnapshotDiff
snapshotDiff as bs = HashMap.filter changed $ alignWith VersionChange (toMap as) (toMap bs)
  where
    toMap = HashMap.fromList . map (pliName &&& pliVersion)