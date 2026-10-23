# Contributing to Songyan

Thanks for helping. Songyan (松烟) is an iOS keyboard built on the RIME engine. This file covers setup, gates, and the project rules.

## Prerequisites

- macOS with full Xcode 27 or later (select it with `xcode-select` or `DEVELOPER_DIR`).
- Python 3.11 or later; the gates and helper scripts use only the standard library.
- For `make lint`: `shellcheck` (`brew install shellcheck`) and `ruff` (used directly, or through `uvx` or `pipx` when installed). `swift-format` ships with Xcode.
- To run on a device under your own Apple team, create the git-ignored `Config/Local.xcconfig` and override any of `SONGYAN_BUNDLE_ID`, `SONGYAN_APP_GROUP` and `DEVELOPMENT_TEAM` from [Config/Identity.xcconfig](Config/Identity.xcconfig).
- To run on a simulator use `make sim-stage`. It signs ad hoc, so the App Group works without a developer account. Unsigned builds (`make build-simulator`, CI) carry no entitlements and must not be used to run the app. See [DEBUG.md](DEBUG.md).

## Repository layout

| Path | Content |
| --- | --- |
| `Apps/HostApp` | host app (scheme management, import, settings) |
| `Apps/KeyboardExtension` | keyboard extension |
| `Apps/SharedKeyboard` | sources compiled into both targets |
| `Packages/` | Swift packages (KeyboardCore, LayoutKit, CandidateKit, PackageManager, RimeBridge, ...) |
| `Tools/`, `Tests/` | CI scripts, engine build tooling, tests |

[ARCHITECTURE.md](ARCHITECTURE.md) is the index of modules, targets, dependencies, data flows and storage paths. Read it before changing a boundary.

## Gates

Run the gate that matches your change. CI runs `make lint`, `make fast` and an unsigned Release device build on every pull request (changes that touch only docs are skipped), and all of them must pass. The Debug device build runs when CI is started by hand and for every release.

| Command | Runs | Use it when |
| --- | --- | --- |
| `make fast` (or `make test`) | structure tests, Swift package tests, offline iOS probes | before every pull request |
| `make lint` | `swift-format lint --strict`, `shellcheck`, `ruff check` on tracked files | before every pull request; `make format` fixes most findings |
| `make structure` | only `Tests/ProjectStructure` | project file, identity, documentation or Info.plist changes |
| `make extended` | `fast` plus native harnesses and unsigned Debug simulator and device builds | engine bridge, T9, grammar or build changes; native harnesses need a macOS engine prefix from `Tools/BuildRime` (see `NATIVE_ENGINE_ROOT` in [ci.sh](Tools/CI/ci.sh)) |
| `make release` | `extended` plus the installed-engine check and Release builds | release candidates |

If you cannot run a gate, say so in the pull request and list what remains unverified.

## Project rules

- Do not edit `Packages/*/Vendored/`. Engine artifacts are produced by [Tools/BuildRimeIOS](Tools/BuildRimeIOS); the slice checksums are recorded in [RimeKitArtifact.json](Packages/RimeBridge/RimeKitArtifact.json) and must not be changed by hand.
- Do not add `PackageManager` to the `KeyboardExtension` target.
- A new `Apps/SharedKeyboard/*.swift` file must be in both targets' Sources phase, exactly once each ([test_pbx_object_graph.py](Tests/ProjectStructure/test_pbx_object_graph.py) checks this).
- Each target keeps its own `PrivacyInfo.xcprivacy`; do not cross-reference them.
- Bundle ids, App Group, entitlements and `declaredGroupID` in `RimePaths.swift` must agree ([test_project_identity_consistency.py](Tests/ProjectStructure/test_project_identity_consistency.py)); change them through `Config/Identity.xcconfig`.
- The engine is a process-wide singleton. Create, start and destroy it only through `EngineOwnershipCoordinator` and `EngineOpQueue`; never add a parallel instance.
- Engine operations run on the serial engine queue. Reads of `active.json`, layouts and appearance go through `KeyboardResourceReadQueue`; no synchronous disk reads on the main thread.
- When a capability cannot be proven, fail closed and fall back to native Rime behavior. Do not fake success or show placeholder UI.
- Ranking and segmentation are the engine's job. The front end must not re-rank or re-segment candidates. The nine-key preedit shows letters for display only; commits always come from the engine.
- Paths in `README.md`, `ARCHITECTURE.md`, `DEBUG.md` and this file must exist ([test_documentation_links.py](Tests/ProjectStructure/test_documentation_links.py)). When you add or move files, update the tables in [ARCHITECTURE.md](ARCHITECTURE.md).

## Code style

- Comments and identifiers are in English; match the surrounding style.
- Formatting follows [.swift-format](.swift-format) (4-space indent, 120 columns) and [.editorconfig](.editorconfig) (UTF-8, LF, final newline, no trailing whitespace; 2 spaces for shell, YAML and JSON). Python follows the ruff settings in [pyproject.toml](pyproject.toml). Run `make format` before committing and `make lint` to check.
- Keep changes focused. Add or update tests with the code they cover, and prefer behavior tests over tests that grep source text.

## Commits and pull requests

Use short conventional commits, for example `fix(candidates): keep reading row height stable`, `feat(layout): ...`, `refactor(...)`, `docs(...)`, `build(...)`, `test(...)`. Describe what changed and why in the pull request, and name the gates you ran.

## Releases

`main` is the development branch. A release is an annotated tag on a commit of `main`:

```sh
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

[release.yml](.github/workflows/release.yml) then runs lint, tests and the Debug device build, builds the app with version `0.2.0` (the build number is the commit count), and publishes a GitHub Release with an ad-hoc signed IPA and notes generated from the commits since the previous tag. A tag with a suffix such as `v0.2.0-beta.1` is published as a pre-release. The IPA is meant for installers that re-sign it under your own Apple ID, such as AltStore or Sideloadly.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

Songyan is licensed under [GPL-3.0-only](LICENSE). By contributing you agree that your contribution is licensed under the same terms. Third-party components and their licenses are listed in [Resources/Legal/ThirdPartyNotices.txt](Resources/Legal/ThirdPartyNotices.txt); do not add a dependency without updating that file.
