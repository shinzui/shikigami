# Producer fixture

This repository publishes one versioned JSON record. Run `python3 local_check.py`
before returning a local commit. The consumer is a separate admitted repository;
its assumptions must be reconciled through the coordinator. Changes are local
edits and tests only. Do not publish, access the network or change these checks.
