# Contributing to Crowsnest

Thanks for helping! Bug reports, ideas and pull requests are welcome.

## Before you start
- For larger changes, open an issue first so we can agree on the approach.
- Everything is **English**: UI strings, code, comments, docs, commit messages.
- Never include real kubeconfigs, tokens, certificates or cluster data in issues, tests or screenshots.

## Development
- macOS with a current Xcode (Swift 6). `make build`, `make test`, `make run` (or `make app` for a `.app`).
- iPad: `make ipad-run` (Simulator). The Xcode project is generated from `App/project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`make xcode`). On first build Xcode asks to trust SwiftTerm's
  build plugin.
- Test against a throwaway cluster (kind, k3d, Docker Desktop). Write actions must never be tested against
  clusters you care about.
- `Sources/CrowsnestKit` must stay UI-free and build for iOS. UI code in `Sources/CrowsnestUI` must compile for
  macOS and iPadOS – put AppKit/UIKit code behind `#if os(macOS)`.

## Pull requests
- Keep them focused; include tests for logic in CrowsnestKit.
- `make build && make test` must pass (CI runs both).
- Sign off your commits (Developer Certificate of Origin, https://developercertificate.org):
  `git commit -s` adds `Signed-off-by: Your Name <you@example.com>`. By signing off you certify that you wrote the
  change or have the right to submit it under the Apache License 2.0.

## Extensions
Features can plug into the app through `CrowsnestExtension` (`Sources/CrowsnestUI/Extensions`) – sidebar pages and
a settings section. The official Altiros build uses this for Crowsnest Pro, which is not part of this repository.

## Security
Please report vulnerabilities privately – see [SECURITY.md](SECURITY.md).
