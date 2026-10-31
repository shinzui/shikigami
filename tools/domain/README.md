# Domain declaration census

Run after building all enabled components with the selected compiler:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests
nix develop --no-write-lock-file -c python3 tools/domain/census.py --output docs/evidence/keiro-0.22/domain-declarations.json
```

The default artifact directory is the current arm64 macOS/GHC 9.12.4 build.
`--build-root` can select another architecture's directory inside this checkout's
`dist-newstyle/build`. Only local, nonsymlink source/interface paths are inputs;
there is no dependency or filesystem-root search. The current Cabal package
version and source component select the interface. In particular, an obsolete
main-library interface cannot substitute for the current inspection sublibrary.

The output enumerates every hand-owned Shikigami library module in the seven
packages, including the inspection and migration test-support components and the
migration version helper. Native generated paths/tooling are excluded by their
producer-owned path. Role entrypoints are separately listed with their declared
type names; their command/argument boundary still needs semantic review.

Each row retains the source hash, interface hash and complete compiler-rendered
data/newtype/type-alias declaration, including positional alternatives. This is
an unclassified audit worklist. Raw primitives can occur in private newtype
representations, incidental values and actual wire/database/library adapters;
none of those categories can be inferred solely from a namespace or serialization.
Review owning factories, invariants, identity authority and consumers before
assigning a disposition. A source/compiled interface inventory is not evidence
of behavior, replay, binary closure or deployment qualification.
