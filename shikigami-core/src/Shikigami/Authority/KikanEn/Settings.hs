-- | The Kikan-En setting values the application configuration decodes. They
-- are re-exported here so that only the Kikan-En adapter modules import the
-- Kikan-En contract.
module Shikigami.Authority.KikanEn.Settings
  ( ActionSchemaHash,
    actionSchemaHashText,
    mkActionSchemaHash,
    actionValueErrorText,
  )
where

import Kikan.En.Action (ActionSchemaHash, actionSchemaHashText, actionValueErrorText, mkActionSchemaHash)
