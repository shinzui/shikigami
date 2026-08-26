# Practice-review content-plane fixtures

This directory defines three deterministic Git histories for the revision-pinned evidence reader.
Each `*.fast-import` stream uses fixed authors, timestamps, messages, paths, and bytes, so importing
it into an empty repository always produces the commit and blob ids recorded in `manifest.json`.

The `snapshots/` tree mirrors the named revisions for tests that need exact bytes without invoking
Git. The Haskell stub returns those bytes with the repository ids, commit ids, and blob ids from the
manifest. Tests never clone a network repository and production code never reads this directory.

To inspect a history manually, initialize an empty temporary Git repository and run, for example:

```bash
git init /tmp/shikigami-target-fixture
git -C /tmp/shikigami-target-fixture fast-import < fixtures/practice-review/content-plane/target.fast-import
git -C /tmp/shikigami-target-fixture show refs/tags/T2:docs/adr/0001.md
```

Use a task-specific temporary directory. Do not import these streams into the Shikigami repository.
