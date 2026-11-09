# Execution lifecycle

# Edge inspector

### ExecutionLifecycleMissing

- **ExecutionLifecycleMissing -> ExecutionLifecycleActive**
  - edge index: 0
  - input: AdmitExecution
  - output: ExecutionAdmitted
  - output fields: ExecutionAdmitted[field 0: AdmitExecution.executionId; field 1: AdmitExecution.snapshotDigest]
  - guard (structural): PInCtor
  - guard (pretty): AdmitExecution
  - written slots: snapshotDigest; executionId

### ExecutionLifecycleActive

- **ExecutionLifecycleActive -> ExecutionLifecycleActive**
  - edge index: 0
  - input: AdvanceExecution
  - output: ExecutionAdvanced
  - output fields: ExecutionAdvanced[field 0: AdvanceExecution.executionId; field 1: AdvanceExecution.expected; field 2: AdvanceExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AdvanceExecution && ((AdvanceExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && AdvanceExecution.expected == revision) && AdvanceExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleParked**
  - edge index: 1
  - input: ParkExecution
  - output: ExecutionParked
  - output fields: ExecutionParked[field 0: ParkExecution.executionId; field 1: ParkExecution.expected; field 2: ParkExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ParkExecution && ((ParkExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && ParkExecution.expected == revision) && ParkExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleUnresolved**
  - edge index: 2
  - input: MarkExecutionUnresolved
  - output: ExecutionBecameUnresolved
  - output fields: ExecutionBecameUnresolved[field 0: MarkExecutionUnresolved.executionId; field 1: MarkExecutionUnresolved.expected; field 2: MarkExecutionUnresolved.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (MarkExecutionUnresolved && ((MarkExecutionUnresolved.executionId.ExecutionIdentity == executionId.ExecutionIdentity && MarkExecutionUnresolved.expected == revision) && MarkExecutionUnresolved.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleSucceeded**
  - edge index: 3
  - input: FinishExecution
  - output: ExecutionFinished
  - output fields: ExecutionFinished[field 0: FinishExecution.executionId; field 1: FinishExecution.expected; field 2: FinishExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (FinishExecution && ((FinishExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FinishExecution.expected == revision) && FinishExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleFailed**
  - edge index: 4
  - input: FailExecution
  - output: ExecutionFailed
  - output fields: ExecutionFailed[field 0: FailExecution.executionId; field 1: FailExecution.expected; field 2: FailExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (FailExecution && ((FailExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecution.expected == revision) && FailExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleCancelled**
  - edge index: 5
  - input: CancelExecution
  - output: ExecutionCancelled
  - output fields: ExecutionCancelled[field 0: CancelExecution.executionId; field 1: CancelExecution.expected; field 2: CancelExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (CancelExecution && ((CancelExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecution.expected == revision) && CancelExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleActive**
  - edge index: 6
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq
  - guard (pretty): (SettleExecutionReceipt && ((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleActive -> ExecutionLifecycleSucceededPendingReceipts**
  - edge index: 7
  - input: FinishExecutionPendingReceipts
  - output: ExecutionFinishedPendingReceipts
  - output fields: ExecutionFinishedPendingReceipts[field 0: FinishExecutionPendingReceipts.executionId; field 1: FinishExecutionPendingReceipts.expected; field 2: FinishExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (FinishExecutionPendingReceipts && (((FinishExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FinishExecutionPendingReceipts.expected == revision) && FinishExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleFailedPendingReceipts**
  - edge index: 8
  - input: FailExecutionPendingReceipts
  - output: ExecutionFailedPendingReceipts
  - output fields: ExecutionFailedPendingReceipts[field 0: FailExecutionPendingReceipts.executionId; field 1: FailExecutionPendingReceipts.expected; field 2: FailExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (FailExecutionPendingReceipts && (((FailExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecutionPendingReceipts.expected == revision) && FailExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision
- **ExecutionLifecycleActive -> ExecutionLifecycleCancelledPendingReceipts**
  - edge index: 9
  - input: CancelExecutionPendingReceipts
  - output: ExecutionCancelledPendingReceipts
  - output fields: ExecutionCancelledPendingReceipts[field 0: CancelExecutionPendingReceipts.executionId; field 1: CancelExecutionPendingReceipts.expected; field 2: CancelExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (CancelExecutionPendingReceipts && (((CancelExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecutionPendingReceipts.expected == revision) && CancelExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision

### ExecutionLifecycleParked

- **ExecutionLifecycleParked -> ExecutionLifecycleActive**
  - edge index: 0
  - input: ResumeExecution
  - output: ExecutionResumed
  - output fields: ExecutionResumed[field 0: ResumeExecution.executionId; field 1: ResumeExecution.expected; field 2: ResumeExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ResumeExecution && ((ResumeExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && ResumeExecution.expected == revision) && ResumeExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleParked -> ExecutionLifecycleFailed**
  - edge index: 1
  - input: FailExecution
  - output: ExecutionFailed
  - output fields: ExecutionFailed[field 0: FailExecution.executionId; field 1: FailExecution.expected; field 2: FailExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (FailExecution && ((FailExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecution.expected == revision) && FailExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleParked -> ExecutionLifecycleCancelled**
  - edge index: 2
  - input: CancelExecution
  - output: ExecutionCancelled
  - output fields: ExecutionCancelled[field 0: CancelExecution.executionId; field 1: CancelExecution.expected; field 2: CancelExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (CancelExecution && ((CancelExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecution.expected == revision) && CancelExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleParked -> ExecutionLifecycleParked**
  - edge index: 3
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq
  - guard (pretty): (SettleExecutionReceipt && ((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleParked -> ExecutionLifecycleFailedPendingReceipts**
  - edge index: 4
  - input: FailExecutionPendingReceipts
  - output: ExecutionFailedPendingReceipts
  - output fields: ExecutionFailedPendingReceipts[field 0: FailExecutionPendingReceipts.executionId; field 1: FailExecutionPendingReceipts.expected; field 2: FailExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (FailExecutionPendingReceipts && (((FailExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecutionPendingReceipts.expected == revision) && FailExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision
- **ExecutionLifecycleParked -> ExecutionLifecycleCancelledPendingReceipts**
  - edge index: 5
  - input: CancelExecutionPendingReceipts
  - output: ExecutionCancelledPendingReceipts
  - output fields: ExecutionCancelledPendingReceipts[field 0: CancelExecutionPendingReceipts.executionId; field 1: CancelExecutionPendingReceipts.expected; field 2: CancelExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (CancelExecutionPendingReceipts && (((CancelExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecutionPendingReceipts.expected == revision) && CancelExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision

### ExecutionLifecycleUnresolved

- **ExecutionLifecycleUnresolved -> ExecutionLifecycleUnresolved**
  - edge index: 0
  - input: MarkExecutionUnresolved
  - output: ExecutionBecameUnresolved
  - output fields: ExecutionBecameUnresolved[field 0: MarkExecutionUnresolved.executionId; field 1: MarkExecutionUnresolved.expected; field 2: MarkExecutionUnresolved.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (MarkExecutionUnresolved && ((MarkExecutionUnresolved.executionId.ExecutionIdentity == executionId.ExecutionIdentity && MarkExecutionUnresolved.expected == revision) && MarkExecutionUnresolved.revision > revision))
  - written slots: revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleActive**
  - edge index: 1
  - input: ReconcileExecution
  - output: ExecutionReconciled
  - output fields: ExecutionReconciled[field 0: ReconcileExecution.executionId; field 1: ReconcileExecution.expected; field 2: ReconcileExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ReconcileExecution && ((ReconcileExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && ReconcileExecution.expected == revision) && ReconcileExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleFailed**
  - edge index: 2
  - input: FailExecution
  - output: ExecutionFailed
  - output fields: ExecutionFailed[field 0: FailExecution.executionId; field 1: FailExecution.expected; field 2: FailExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (FailExecution && ((FailExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecution.expected == revision) && FailExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleCancelled**
  - edge index: 3
  - input: CancelExecution
  - output: ExecutionCancelled
  - output fields: ExecutionCancelled[field 0: CancelExecution.executionId; field 1: CancelExecution.expected; field 2: CancelExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (CancelExecution && ((CancelExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecution.expected == revision) && CancelExecution.revision > revision))
  - written slots: revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleActive**
  - edge index: 4
  - input: RetryExecution
  - output: ExecutionRetried
  - output fields: ExecutionRetried[field 0: RetryExecution.executionId; field 1: RetryExecution.expected; field 2: RetryExecution.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RetryExecution && ((RetryExecution.executionId.ExecutionIdentity == executionId.ExecutionIdentity && RetryExecution.expected == revision) && RetryExecution.revision > revision))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleUnresolved**
  - edge index: 5
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq
  - guard (pretty): (SettleExecutionReceipt && ((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleFailedPendingReceipts**
  - edge index: 6
  - input: FailExecutionPendingReceipts
  - output: ExecutionFailedPendingReceipts
  - output fields: ExecutionFailedPendingReceipts[field 0: FailExecutionPendingReceipts.executionId; field 1: FailExecutionPendingReceipts.expected; field 2: FailExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (FailExecutionPendingReceipts && (((FailExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && FailExecutionPendingReceipts.expected == revision) && FailExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision
- **ExecutionLifecycleUnresolved -> ExecutionLifecycleCancelledPendingReceipts**
  - edge index: 7
  - input: CancelExecutionPendingReceipts
  - output: ExecutionCancelledPendingReceipts
  - output fields: ExecutionCancelledPendingReceipts[field 0: CancelExecutionPendingReceipts.executionId; field 1: CancelExecutionPendingReceipts.expected; field 2: CancelExecutionPendingReceipts.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt
  - guard (pretty): (CancelExecutionPendingReceipts && (((CancelExecutionPendingReceipts.executionId.ExecutionIdentity == executionId.ExecutionIdentity && CancelExecutionPendingReceipts.expected == revision) && CancelExecutionPendingReceipts.revision > revision) && pendingReceipts > 0))
  - written slots: revision

### ExecutionLifecycleSucceededPendingReceipts

- **ExecutionLifecycleSucceededPendingReceipts -> ExecutionLifecycleSucceededPendingReceipts**
  - edge index: 0
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PCmp CmpGt
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining > 0))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleSucceededPendingReceipts -> ExecutionLifecycleSucceeded**
  - edge index: 1
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptsClosed
  - output fields: ExecutionReceiptsClosed[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PEq
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining == 0))
  - written slots: pendingReceipts; revision

### ExecutionLifecycleFailedPendingReceipts

- **ExecutionLifecycleFailedPendingReceipts -> ExecutionLifecycleFailedPendingReceipts**
  - edge index: 0
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PCmp CmpGt
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining > 0))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleFailedPendingReceipts -> ExecutionLifecycleFailed**
  - edge index: 1
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptsClosed
  - output fields: ExecutionReceiptsClosed[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PEq
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining == 0))
  - written slots: pendingReceipts; revision

### ExecutionLifecycleCancelledPendingReceipts

- **ExecutionLifecycleCancelledPendingReceipts -> ExecutionLifecycleCancelledPendingReceipts**
  - edge index: 0
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptSettled
  - output fields: ExecutionReceiptSettled[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PCmp CmpGt
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining > 0))
  - written slots: pendingReceipts; revision
- **ExecutionLifecycleCancelledPendingReceipts -> ExecutionLifecycleCancelled**
  - edge index: 1
  - input: SettleExecutionReceipt
  - output: ExecutionReceiptsClosed
  - output fields: ExecutionReceiptsClosed[field 0: SettleExecutionReceipt.executionId; field 1: SettleExecutionReceipt.expected; field 2: SettleExecutionReceipt.revision; field 3: SettleExecutionReceipt.remaining]
  - guard (structural): PAnd PInCtor PAnd PAnd PAnd PAnd PAnd PEq PEq PCmp CmpGt PCmp CmpGt PEq PEq
  - guard (pretty): (SettleExecutionReceipt && (((((SettleExecutionReceipt.executionId.ExecutionIdentity == executionId.ExecutionIdentity && SettleExecutionReceipt.expected == revision) && SettleExecutionReceipt.revision > revision) && pendingReceipts > 0) && SettleExecutionReceipt.remaining == (pendingReceipts - 1)) && SettleExecutionReceipt.remaining == 0))
  - written slots: pendingReceipts; revision

# Worker session lifecycle

# Edge inspector

### WorkerSessionLifecycleMissing

- **WorkerSessionLifecycleMissing -> WorkerSessionLifecycleIdle**
  - edge index: 0
  - input: AdmitWorkerSession
  - output: WorkerSessionAdmitted
  - output fields: WorkerSessionAdmitted[field 0: AdmitWorkerSession.sessionId; field 1: AdmitWorkerSession.bindingDigest]
  - guard (structural): PInCtor
  - guard (pretty): AdmitWorkerSession
  - written slots: bindingDigest; sessionId

### WorkerSessionLifecycleIdle

- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 0
  - input: AcceptSessionMessage
  - output: SessionMessageAccepted
  - output fields: SessionMessageAccepted[field 0: AcceptSessionMessage.sessionId; field 1: AcceptSessionMessage.expected; field 2: AcceptSessionMessage.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AcceptSessionMessage && ((AcceptSessionMessage.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && AcceptSessionMessage.expected == revision) && AcceptSessionMessage.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 1
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 2
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 3
  - input: ObserveWorkerSession
  - output: WorkerSessionObserved
  - output fields: WorkerSessionObserved[field 0: ObserveWorkerSession.sessionId; field 1: ObserveWorkerSession.expected; field 2: ObserveWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ObserveWorkerSession && ((ObserveWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ObserveWorkerSession.expected == revision) && ObserveWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleActive**
  - edge index: 4
  - input: StartSessionAssignment
  - output: SessionAssignmentStarted
  - output fields: SessionAssignmentStarted[field 0: StartSessionAssignment.sessionId; field 1: StartSessionAssignment.expected; field 2: StartSessionAssignment.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (StartSessionAssignment && ((StartSessionAssignment.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && StartSessionAssignment.expected == revision) && StartSessionAssignment.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleFailed**
  - edge index: 5
  - input: FailWorkerSession
  - output: WorkerSessionFailed
  - output fields: WorkerSessionFailed[field 0: FailWorkerSession.sessionId; field 1: FailWorkerSession.expected; field 2: FailWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (FailWorkerSession && ((FailWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && FailWorkerSession.expected == revision) && FailWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleCancelled**
  - edge index: 6
  - input: CancelWorkerSession
  - output: WorkerSessionCancelled
  - output fields: WorkerSessionCancelled[field 0: CancelWorkerSession.sessionId; field 1: CancelWorkerSession.expected; field 2: CancelWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (CancelWorkerSession && ((CancelWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && CancelWorkerSession.expected == revision) && CancelWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleTransferring**
  - edge index: 7
  - input: RequestSessionTransfer
  - output: SessionTransferRequested
  - output fields: SessionTransferRequested[field 0: RequestSessionTransfer.sessionId; field 1: RequestSessionTransfer.expected; field 2: RequestSessionTransfer.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RequestSessionTransfer && ((RequestSessionTransfer.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RequestSessionTransfer.expected == revision) && RequestSessionTransfer.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 8
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleIdle -> WorkerSessionLifecycleIdle**
  - edge index: 9
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleActive

- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 0
  - input: AcceptSessionMessage
  - output: SessionMessageAccepted
  - output fields: SessionMessageAccepted[field 0: AcceptSessionMessage.sessionId; field 1: AcceptSessionMessage.expected; field 2: AcceptSessionMessage.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AcceptSessionMessage && ((AcceptSessionMessage.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && AcceptSessionMessage.expected == revision) && AcceptSessionMessage.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 1
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 2
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 3
  - input: ObserveWorkerSession
  - output: WorkerSessionObserved
  - output fields: WorkerSessionObserved[field 0: ObserveWorkerSession.sessionId; field 1: ObserveWorkerSession.expected; field 2: ObserveWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ObserveWorkerSession && ((ObserveWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ObserveWorkerSession.expected == revision) && ObserveWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleParked**
  - edge index: 4
  - input: ParkSessionAssignment
  - output: SessionAssignmentParked
  - output fields: SessionAssignmentParked[field 0: ParkSessionAssignment.sessionId; field 1: ParkSessionAssignment.expected; field 2: ParkSessionAssignment.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ParkSessionAssignment && ((ParkSessionAssignment.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ParkSessionAssignment.expected == revision) && ParkSessionAssignment.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleIdle**
  - edge index: 5
  - input: RecordSessionResult
  - output: SessionResultRecorded
  - output fields: SessionResultRecorded[field 0: RecordSessionResult.sessionId; field 1: RecordSessionResult.expected; field 2: RecordSessionResult.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RecordSessionResult && ((RecordSessionResult.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RecordSessionResult.expected == revision) && RecordSessionResult.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleUnresolved**
  - edge index: 6
  - input: MarkSessionUnresolved
  - output: SessionBecameUnresolved
  - output fields: SessionBecameUnresolved[field 0: MarkSessionUnresolved.sessionId; field 1: MarkSessionUnresolved.expected; field 2: MarkSessionUnresolved.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (MarkSessionUnresolved && ((MarkSessionUnresolved.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && MarkSessionUnresolved.expected == revision) && MarkSessionUnresolved.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleTransferring**
  - edge index: 7
  - input: RequestSessionTransfer
  - output: SessionTransferRequested
  - output fields: SessionTransferRequested[field 0: RequestSessionTransfer.sessionId; field 1: RequestSessionTransfer.expected; field 2: RequestSessionTransfer.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RequestSessionTransfer && ((RequestSessionTransfer.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RequestSessionTransfer.expected == revision) && RequestSessionTransfer.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 8
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleActive -> WorkerSessionLifecycleActive**
  - edge index: 9
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleParked

- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 0
  - input: AcceptSessionMessage
  - output: SessionMessageAccepted
  - output fields: SessionMessageAccepted[field 0: AcceptSessionMessage.sessionId; field 1: AcceptSessionMessage.expected; field 2: AcceptSessionMessage.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AcceptSessionMessage && ((AcceptSessionMessage.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && AcceptSessionMessage.expected == revision) && AcceptSessionMessage.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 1
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 2
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 3
  - input: ObserveWorkerSession
  - output: WorkerSessionObserved
  - output fields: WorkerSessionObserved[field 0: ObserveWorkerSession.sessionId; field 1: ObserveWorkerSession.expected; field 2: ObserveWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ObserveWorkerSession && ((ObserveWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ObserveWorkerSession.expected == revision) && ObserveWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleActive**
  - edge index: 4
  - input: ResumeSessionAssignment
  - output: SessionAssignmentResumed
  - output fields: SessionAssignmentResumed[field 0: ResumeSessionAssignment.sessionId; field 1: ResumeSessionAssignment.expected; field 2: ResumeSessionAssignment.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ResumeSessionAssignment && ((ResumeSessionAssignment.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ResumeSessionAssignment.expected == revision) && ResumeSessionAssignment.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleUnresolved**
  - edge index: 5
  - input: MarkSessionUnresolved
  - output: SessionBecameUnresolved
  - output fields: SessionBecameUnresolved[field 0: MarkSessionUnresolved.sessionId; field 1: MarkSessionUnresolved.expected; field 2: MarkSessionUnresolved.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (MarkSessionUnresolved && ((MarkSessionUnresolved.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && MarkSessionUnresolved.expected == revision) && MarkSessionUnresolved.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleTransferring**
  - edge index: 6
  - input: RequestSessionTransfer
  - output: SessionTransferRequested
  - output fields: SessionTransferRequested[field 0: RequestSessionTransfer.sessionId; field 1: RequestSessionTransfer.expected; field 2: RequestSessionTransfer.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RequestSessionTransfer && ((RequestSessionTransfer.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RequestSessionTransfer.expected == revision) && RequestSessionTransfer.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 7
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleParked -> WorkerSessionLifecycleParked**
  - edge index: 8
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleUnresolved

- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 0
  - input: AcceptSessionMessage
  - output: SessionMessageAccepted
  - output fields: SessionMessageAccepted[field 0: AcceptSessionMessage.sessionId; field 1: AcceptSessionMessage.expected; field 2: AcceptSessionMessage.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AcceptSessionMessage && ((AcceptSessionMessage.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && AcceptSessionMessage.expected == revision) && AcceptSessionMessage.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 1
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 2
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 3
  - input: ObserveWorkerSession
  - output: WorkerSessionObserved
  - output fields: WorkerSessionObserved[field 0: ObserveWorkerSession.sessionId; field 1: ObserveWorkerSession.expected; field 2: ObserveWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ObserveWorkerSession && ((ObserveWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ObserveWorkerSession.expected == revision) && ObserveWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleActive**
  - edge index: 4
  - input: ReconcileSessionAssignment
  - output: SessionAssignmentReconciled
  - output fields: SessionAssignmentReconciled[field 0: ReconcileSessionAssignment.sessionId; field 1: ReconcileSessionAssignment.expected; field 2: ReconcileSessionAssignment.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ReconcileSessionAssignment && ((ReconcileSessionAssignment.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ReconcileSessionAssignment.expected == revision) && ReconcileSessionAssignment.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleTransferring**
  - edge index: 5
  - input: RequestSessionTransfer
  - output: SessionTransferRequested
  - output fields: SessionTransferRequested[field 0: RequestSessionTransfer.sessionId; field 1: RequestSessionTransfer.expected; field 2: RequestSessionTransfer.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RequestSessionTransfer && ((RequestSessionTransfer.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RequestSessionTransfer.expected == revision) && RequestSessionTransfer.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 6
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleUnresolved -> WorkerSessionLifecycleUnresolved**
  - edge index: 7
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleTransferring

- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 0
  - input: AcceptSessionMessage
  - output: SessionMessageAccepted
  - output fields: SessionMessageAccepted[field 0: AcceptSessionMessage.sessionId; field 1: AcceptSessionMessage.expected; field 2: AcceptSessionMessage.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AcceptSessionMessage && ((AcceptSessionMessage.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && AcceptSessionMessage.expected == revision) && AcceptSessionMessage.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 1
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 2
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 3
  - input: ObserveWorkerSession
  - output: WorkerSessionObserved
  - output fields: WorkerSessionObserved[field 0: ObserveWorkerSession.sessionId; field 1: ObserveWorkerSession.expected; field 2: ObserveWorkerSession.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ObserveWorkerSession && ((ObserveWorkerSession.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ObserveWorkerSession.expected == revision) && ObserveWorkerSession.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 4
  - input: RecordSessionResult
  - output: SessionResultRecorded
  - output fields: SessionResultRecorded[field 0: RecordSessionResult.sessionId; field 1: RecordSessionResult.expected; field 2: RecordSessionResult.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (RecordSessionResult && ((RecordSessionResult.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && RecordSessionResult.expected == revision) && RecordSessionResult.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 5
  - input: ReconcileSessionTransfer
  - output: SessionTransferReconciled
  - output fields: SessionTransferReconciled[field 0: ReconcileSessionTransfer.sessionId; field 1: ReconcileSessionTransfer.expected; field 2: ReconcileSessionTransfer.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ReconcileSessionTransfer && ((ReconcileSessionTransfer.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ReconcileSessionTransfer.expected == revision) && ReconcileSessionTransfer.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleIdle**
  - edge index: 6
  - input: EstablishSessionOwner
  - output: SessionOwnerEstablished
  - output fields: SessionOwnerEstablished[field 0: EstablishSessionOwner.sessionId; field 1: EstablishSessionOwner.expected; field 2: EstablishSessionOwner.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (EstablishSessionOwner && ((EstablishSessionOwner.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && EstablishSessionOwner.expected == revision) && EstablishSessionOwner.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 7
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleTransferring -> WorkerSessionLifecycleTransferring**
  - edge index: 8
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleFailed

- **WorkerSessionLifecycleFailed -> WorkerSessionLifecycleFailed**
  - edge index: 0
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleFailed -> WorkerSessionLifecycleFailed**
  - edge index: 1
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleFailed -> WorkerSessionLifecycleFailed**
  - edge index: 2
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleFailed -> WorkerSessionLifecycleFailed**
  - edge index: 3
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

### WorkerSessionLifecycleCancelled

- **WorkerSessionLifecycleCancelled -> WorkerSessionLifecycleCancelled**
  - edge index: 0
  - input: ConsumeSessionEvents
  - output: SessionEventsConsumed
  - output fields: SessionEventsConsumed[field 0: ConsumeSessionEvents.sessionId; field 1: ConsumeSessionEvents.expected; field 2: ConsumeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ConsumeSessionEvents && ((ConsumeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && ConsumeSessionEvents.expected == revision) && ConsumeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleCancelled -> WorkerSessionLifecycleCancelled**
  - edge index: 1
  - input: PrepareSessionCheckpoint
  - output: SessionCheckpointPrepared
  - output fields: SessionCheckpointPrepared[field 0: PrepareSessionCheckpoint.sessionId; field 1: PrepareSessionCheckpoint.expected; field 2: PrepareSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (PrepareSessionCheckpoint && ((PrepareSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && PrepareSessionCheckpoint.expected == revision) && PrepareSessionCheckpoint.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleCancelled -> WorkerSessionLifecycleCancelled**
  - edge index: 2
  - input: SubscribeSessionEvents
  - output: SessionEventsSubscribed
  - output fields: SessionEventsSubscribed[field 0: SubscribeSessionEvents.sessionId; field 1: SubscribeSessionEvents.expected; field 2: SubscribeSessionEvents.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SubscribeSessionEvents && ((SubscribeSessionEvents.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SubscribeSessionEvents.expected == revision) && SubscribeSessionEvents.revision > revision))
  - written slots: revision
- **WorkerSessionLifecycleCancelled -> WorkerSessionLifecycleCancelled**
  - edge index: 3
  - input: SupersedeSessionCheckpoint
  - output: SessionCheckpointSuperseded
  - output fields: SessionCheckpointSuperseded[field 0: SupersedeSessionCheckpoint.sessionId; field 1: SupersedeSessionCheckpoint.expected; field 2: SupersedeSessionCheckpoint.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (SupersedeSessionCheckpoint && ((SupersedeSessionCheckpoint.sessionId.WorkerSessionIdentity == sessionId.WorkerSessionIdentity && SupersedeSessionCheckpoint.expected == revision) && SupersedeSessionCheckpoint.revision > revision))
  - written slots: revision

# Objective lifecycle

# Edge inspector

### ObjectiveLifecycleMissing

- **ObjectiveLifecycleMissing -> ObjectiveLifecyclePresent**
  - edge index: 0
  - input: CreateObjective
  - output: ObjectiveCreated
  - output fields: ObjectiveCreated[field 0: CreateObjective.objectiveId]
  - guard (structural): PInCtor
  - guard (pretty): CreateObjective
  - written slots: objectiveId

### ObjectiveLifecyclePresent

- **ObjectiveLifecyclePresent -> ObjectiveLifecyclePresent**
  - edge index: 0
  - input: ApplyObjectiveTransition
  - output: ObjectiveTransitionApplied
  - output fields: ObjectiveTransitionApplied[field 0: ApplyObjectiveTransition.objectiveId; field 1: ApplyObjectiveTransition.expected; field 2: ApplyObjectiveTransition.revision; field 3: ApplyObjectiveTransition.fingerprint]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (ApplyObjectiveTransition && ((ApplyObjectiveTransition.objectiveId.ObjectiveId == objectiveId.ObjectiveId && ApplyObjectiveTransition.expected == revision) && ApplyObjectiveTransition.revision > revision))
  - written slots: revision
- **ObjectiveLifecyclePresent -> ObjectiveLifecyclePresent**
  - edge index: 1
  - input: RecordTrackerTransition
  - output: TrackerTransitionRecorded
  - output fields: TrackerTransitionRecorded[field 0: RecordTrackerTransition.objectiveId; field 1: RecordTrackerTransition.expected; field 2: RecordTrackerTransition.fingerprint]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (RecordTrackerTransition && (RecordTrackerTransition.objectiveId.ObjectiveId == objectiveId.ObjectiveId && RecordTrackerTransition.expected == revision))

# Mandate lifecycle

# Edge inspector

### MandateLifecycleMissing

- **MandateLifecycleMissing -> MandateLifecycleActive**
  - edge index: 0
  - input: AdmitMandate
  - output: MandateAdmitted
  - output fields: MandateAdmitted[field 0: AdmitMandate.mandateId]
  - guard (structural): PInCtor
  - guard (pretty): AdmitMandate
  - written slots: mandateId

### MandateLifecycleActive

- **MandateLifecycleActive -> MandateLifecycleActive**
  - edge index: 0
  - input: AdvanceMandate
  - output: MandateAdvanced
  - output fields: MandateAdvanced[field 0: AdvanceMandate.mandateId; field 1: AdvanceMandate.expected; field 2: AdvanceMandate.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (AdvanceMandate && ((AdvanceMandate.mandateId == mandateId && AdvanceMandate.expected == revision) && AdvanceMandate.revision > revision))
  - written slots: revision
- **MandateLifecycleActive -> MandateLifecycleStopped**
  - edge index: 1
  - input: StopMandate
  - output: MandateStopped
  - output fields: MandateStopped[field 0: StopMandate.mandateId; field 1: StopMandate.expected; field 2: StopMandate.revision]
  - guard (structural): PAnd PInCtor PAnd PAnd PEq PEq PCmp CmpGt
  - guard (pretty): (StopMandate && ((StopMandate.mandateId == mandateId && StopMandate.expected == revision) && StopMandate.revision > revision))
  - written slots: revision

# Run evidence

# Edge inspector

### RunEvidenceRequested

- **RunEvidenceRequested -> RunEvidenceProfileResolved**
  - edge index: 0
  - input: BindProfile
  - output: ProfileBound
  - output fields: ProfileBound[field 0: BindProfile.runEvidenceId; field 1: BindProfile.runId]
  - guard (structural): PInCtor
  - guard (pretty): BindProfile
  - written slots: runId; runEvidenceId

### RunEvidenceProfileResolved

- **RunEvidenceProfileResolved -> RunEvidenceRunning**
  - edge index: 0
  - input: StartCollection
  - output: CollectionStarted
  - output fields: CollectionStarted[field 0: StartCollection.runEvidenceId; field 1: StartCollection.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (StartCollection && (StartCollection.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && StartCollection.runId == runId))

### RunEvidenceRunning

- **RunEvidenceRunning -> RunEvidenceEvidenceSealed**
  - edge index: 0
  - input: SealEvidence
  - output: EvidenceSealed
  - output fields: EvidenceSealed[field 0: SealEvidence.runEvidenceId; field 1: SealEvidence.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (SealEvidence && (SealEvidence.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && SealEvidence.runId == runId))
- **RunEvidenceRunning -> RunEvidenceNonConforming**
  - edge index: 1
  - input: MarkNonConforming
  - output: EvidenceNonConforming
  - output fields: EvidenceNonConforming[field 0: MarkNonConforming.runEvidenceId; field 1: MarkNonConforming.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (MarkNonConforming && (MarkNonConforming.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && MarkNonConforming.runId == runId))
- **RunEvidenceRunning -> RunEvidenceIncomplete**
  - edge index: 2
  - input: MarkIncomplete
  - output: EvidenceIncomplete
  - output fields: EvidenceIncomplete[field 0: MarkIncomplete.runEvidenceId; field 1: MarkIncomplete.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (MarkIncomplete && (MarkIncomplete.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && MarkIncomplete.runId == runId))
- **RunEvidenceRunning -> RunEvidenceFailed**
  - edge index: 3
  - input: MarkFailed
  - output: EvidenceFailed
  - output fields: EvidenceFailed[field 0: MarkFailed.runEvidenceId; field 1: MarkFailed.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (MarkFailed && (MarkFailed.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && MarkFailed.runId == runId))

### RunEvidenceEvidenceSealed

- **RunEvidenceEvidenceSealed -> RunEvidenceAttested**
  - edge index: 0
  - input: MarkAttested
  - output: EvidenceAttested
  - output fields: EvidenceAttested[field 0: MarkAttested.runEvidenceId; field 1: MarkAttested.runId]
  - guard (structural): PAnd PInCtor PAnd PEq PEq
  - guard (pretty): (MarkAttested && (MarkAttested.runEvidenceId.RunEvidenceId == runEvidenceId.RunEvidenceId && MarkAttested.runId == runId))

# At-risk customer (diagram only)

# Edge inspector

### Observed

- **Observed -> SettledLow**
  - edge index: 0
  - input: ClassifyLowRisk
  - output: ε
  - guard (structural): PInCtor
  - guard (pretty): ClassifyLowRisk
- **Observed -> AwaitingAck**
  - edge index: 1
  - input: ClassifyHighRisk
  - output: ε
  - guard (structural): PInCtor
  - guard (pretty): ClassifyHighRisk

### AwaitingAck

- **AwaitingAck -> Acknowledged**
  - edge index: 0
  - input: Acknowledge
  - output: ε
  - guard (structural): PInCtor
  - guard (pretty): Acknowledge
- **AwaitingAck -> Escalated**
  - edge index: 1
  - input: DeadlineExpired
  - output: ε
  - guard (structural): PInCtor
  - guard (pretty): DeadlineExpired