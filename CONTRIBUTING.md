# Contributing to Tinycast Legacy

Tinycast Legacy is a personal fork of [Tinycast](https://github.com/abue-ammar/tinycast). There is no
upstream to keep pace with and no issue-approval or pull-request gate: work happens directly on this
repository.

Anything you send is taken under the [AGPL-3.0 license](LICENSE), the same terms the project ships
under.

## Setup

- macOS 14.4+ and Xcode 16.2 with Swift 6.0. The `xcode16-local` branch is the one that builds there.
- Run `./Scripts/local-signing.sh` once. Builds sign with that stable identity, which is what keeps
  macOS from forgetting the Accessibility grant on every rebuild.
- `open Tinycast.xcodeproj` → ⌘R. Debug builds are their own channel (`Tinycast Legacy Dev.app`).
- After editing `project.yml`: `xcodegen generate`, and commit the result. No SwiftPM.
- Details: [`docs/development.md`](docs/development.md). Architecture:
  [`docs/architecture.md`](docs/architecture.md). Start at [`docs/`](docs/README.md).

## Before finishing

- [`docs/testing.md`](docs/testing.md#definition-of-done) passes — harnesses, lint, purity, a clean
  build. There is no CI, so run `./Scripts/run-tests.sh`, `./Scripts/lint.sh` and a build locally.
- Leak-tested, with memory numbers. Tinycast stays under 100 MB, and memory returns to baseline after
  the palette closes.
- You actually used the app, on your path and the ones next to it.
- Anything in [`docs/`](docs/) your change makes wrong is fixed in the same commit.

## Code style

Read [`AGENTS.md`](AGENTS.md) first — the posture, the Non-negotiables and the naming and comment rules
apply to a human contributor exactly as they do to an agent. [`docs/standards.md`](docs/standards.md)
is the full version: architecture, naming, Swift style, concurrency and the performance budgets.
[`docs/ui.md`](docs/ui.md) before any new view or restyle.

Commit messages imperative: `Add per-app hotkey toggle`. Behaviour you did not mean to change did not
change; say so explicitly when it did.

## Bugs

macOS version, Tinycast Legacy version and channel, steps, expected vs actual. A recording beats a
paragraph.

## Security

Not in the issue tracker — see [`SECURITY.md`](SECURITY.md).
