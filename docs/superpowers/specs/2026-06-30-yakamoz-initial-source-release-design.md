# Yakamoz Initial Source Release Design

Date: 2026-06-30
Status: Approved for implementation planning

## Goal

Prepare Yakamoz for an initial public GitHub source release at `git@github.com:phynics/Yakamoz.git`.
The release should be understandable and buildable from a standalone public checkout, legally clear
under Apache-2.0, and explicit about Yakamoz's security tradeoffs as a local, non-sandboxed macOS
showcase app.

This is a source release, not a signed binary distribution.

## Scope

In scope:

- Add the Yakamoz Git remote `origin` pointing at `git@github.com:phynics/Yakamoz.git`.
- Add an Apache-2.0 `LICENSE` file to Yakamoz.
- Switch Yakamoz's `project.yml` PositronicKit dependency from the local sibling path
  `../PositronicKit` to the public package URL `https://github.com/phynics/PositronicKit.git`.
- Update Yakamoz's README for public clone/build instructions with no sibling-checkout requirement.
- Keep Yakamoz README links to PositronicKit accurate and prominent.
- Update PositronicKit's README to reference Yakamoz as the native macOS showcase host app.
- Remove or replace Makefile checks that assume `../PositronicKit/Package.resolved`.
- Verify generated project and test workflow after the dependency change.
- Commit Yakamoz and PositronicKit changes separately in their own repositories.

Out of scope:

- Publishing a signed app, release asset, Homebrew cask, or notarized binary.
- Making Yakamoz sandboxed.
- Replacing plaintext `UserDefaults` API-key storage.
- Converting Yakamoz to a Swift package.
- Tagging a stable 1.0 API.
- Rewriting PositronicKit packaging.
- Performing a full Git history secret scrub.

## Current State

Yakamoz is a generated Xcode project driven by `project.yml`. It currently consumes PositronicKit
through a sibling path dependency:

```yaml
packages:
  PositronicKit:
    path: ../PositronicKit
```

This works in the local monorepo-style workspace but does not work for a standalone public Yakamoz
checkout. The existing GitHub Actions workflow checks out only Yakamoz and runs `make verify`, so
CI also depends on removing or replacing the sibling checkout assumption.

Yakamoz's tracked files already exclude generated and local artifacts such as `Yakamoz.xcodeproj/`,
`DerivedData/`, and `.build/`. README documentation already discloses important local-app security
tradeoffs: non-sandboxed folder and terminal workspaces, per-command terminal approval, and plaintext
API-key storage in `UserDefaults`.

PositronicKit is already a public-shaped Swift package with remote URL
`https://github.com/phynics/PositronicKit.git`.

## Approach

Use a focused source-release polish pass with remote SwiftPM dependency resolution.

Yakamoz should depend on the public PositronicKit package URL rather than a sibling checkout. This
allows a fresh clone of Yakamoz to generate and build the Xcode project without requiring users to
manually reproduce the local workspace layout.

The dependency should stay pinned or constrained in the same conservative spirit as the current
`swift-json-schema` exact pin. If a branch dependency is used for the initial source drop, the README
must state that the project tracks PositronicKit's `main` until stable release tags exist. If a tagged
PositronicKit release exists before implementation, prefer the tag for reproducibility.

## Yakamoz Changes

1. Add `LICENSE` with the Apache License, Version 2.0.
2. Add Git remote:

   ```bash
   git remote add origin git@github.com:phynics/Yakamoz.git
   ```

3. Update `project.yml`:

   - Replace `packages.PositronicKit.path: ../PositronicKit` with
     `packages.PositronicKit.url: https://github.com/phynics/PositronicKit.git`.
   - Use the most reproducible available requirement:
     - Prefer an exact tag if PositronicKit has a suitable release tag.
     - Otherwise use `branch: main` and document that this is pre-release source-drop behavior.

4. Update `Makefile`:

   - Remove the `POSITRONICKIT_RESOLVED = ../PositronicKit/Package.resolved` assumption.
   - Preserve a useful verification gate. The gate may either:
     - read Yakamoz's resolved package metadata after Xcode package resolution, or
     - drop `check-json-schema-pin` if the remote PositronicKit graph plus Yakamoz's direct exact
       `swift-json-schema` package constraint already gives Xcode a single consistent resolution.

5. Update `README.md`:

   - Replace sibling-checkout prerequisites with public clone instructions.
   - Link PositronicKit using `https://github.com/phynics/PositronicKit`.
   - State that Yakamoz is Apache-2.0 licensed.
   - Keep the existing local-app/security caveats visible.
   - Mention that Yakamoz is a source release and not a signed/notarized app distribution.
   - Ensure `make generate`, `make build`, `make test`, and `make verify` remain accurate.

6. Keep generated artifacts untracked:

   - `Yakamoz.xcodeproj/`
   - `DerivedData/`
   - `.build/`
   - `.worktrees/`

## PositronicKit Changes

Update `README.md` with a short companion-app section linking to Yakamoz. The section should explain
that Yakamoz is a native macOS showcase app for PositronicKit's prompt pipeline, turn inspection,
tool traces, provider adapters, and local workspace integration.

No PositronicKit code or package manifest changes are required unless Yakamoz's remote dependency
resolution exposes a real packaging issue.

## Verification

For Yakamoz:

```bash
make generate
make verify
```

`make verify` remains the primary gate because it generates the Xcode project, runs the macOS test
suite, and fails if zero tests execute.

For PositronicKit:

```bash
git diff -- README.md
```

If only README changes are made, no full package test is required. If package or code changes become
necessary, run the relevant PositronicKit verification command before committing.

## Risks

- If Yakamoz tracks PositronicKit `main`, public checkouts may be less reproducible than a tagged
  dependency. This is acceptable for the initial source drop only if documented.
- XcodeGen's generated project and Xcode's package resolver may update generated or resolved files.
  Generated artifacts should remain untracked unless the repository intentionally starts tracking a
  lockfile.
- Yakamoz's accepted security tradeoffs are significant. The README must keep them explicit so users
  do not mistake this for a hardened production chat client.

## Acceptance Criteria

- A fresh public checkout of Yakamoz has enough documented information to install prerequisites,
  generate the Xcode project, and run verification.
- Yakamoz has an Apache-2.0 license file.
- Yakamoz references PositronicKit with the public GitHub URL.
- PositronicKit references Yakamoz as its native macOS showcase app.
- Yakamoz no longer requires `../PositronicKit` to exist for the normal public build path.
- `make verify` succeeds or any remaining external prerequisite is documented clearly.
- Yakamoz and PositronicKit changes are committed separately.
