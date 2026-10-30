# Dependency provenance

The application has no third-party runtime dependency besides the fixed on-chain
SqueekCore proxy. `RoundHeap` is internal application code, so compilation leaves
no external library link references.

Test support is vendored under `lib/forge-std/` as ordinary files:

- Upstream: https://github.com/foundry-rs/forge-std
- Release: v1.9.7
- Exact commit: `77041d2ce690e692d6e03cc812b57d1ddaa4d505`
- Retrieved from the GitHub codeload archive for that commit.
- Included: `src/`, `LICENSE-APACHE`, `LICENSE-MIT`.
- Unneeded upstream tests, CI, package metadata and Git metadata are not included.
- Remapping: `forge-std/=lib/forge-std/src/`.

No submodule, network install, generated package cache or `node_modules` is
needed by the verifier. Foundry and solc 0.8.26 are execution tools supplied by
the check environment; no compiler binary is vendored.

The SqueekCore ABI is an integration input, not a local runtime implementation.
Its provenance and verification limitations are in
[docs/ABI_PROVENANCE.md](docs/ABI_PROVENANCE.md). The test mock implements the
read interface and sparse ledger semantics; it does not implement reporter
signature authorization and must not be deployed as an application.

