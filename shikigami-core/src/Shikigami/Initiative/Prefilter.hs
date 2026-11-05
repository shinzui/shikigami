-- | The deterministic pre-filter. The stream consumer and the Flow call the same
-- total function, so their verdicts cannot disagree and no run trusts intake.
module Shikigami.Initiative.Prefilter (prefilter) where

import Data.Foldable (toList)
import Data.Text qualified as Text
import Shikigami.Initiative.Settings (ObserverAllowance (..), allowanceView)
import Shikigami.Initiative.Types
import Shikigami.Initiative.Types.Internal (Candidate (..))

prefilter :: ObserverAllowance -> Observed -> Either SkipReason Candidate
prefilter allowance observed
  | observed.kind `notElem` toList allowance.sources = Left SourceNotPermitted
  | Text.length (excerptText observed.excerpt) < initiativeLimitInt allowance.minimumExcerptLength = Left ExcerptTooShort
  | otherwise =
      Right
        ( Candidate
            CandidateFacts
              { observer = allowance.principal,
                observed,
                evidence =
                  EvidenceRef
                    { activity = observed.activity,
                      subject = observed.subject,
                      occurredAt = observed.occurredAt,
                      digest = excerptDigestFor observed.excerpt
                    },
                allowance = allowanceView allowance
              }
        )
