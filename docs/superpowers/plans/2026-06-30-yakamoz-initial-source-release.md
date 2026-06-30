# Yakamoz Initial Source Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare Yakamoz for a public GitHub source release that builds from a standalone checkout and clearly references PositronicKit.

**Architecture:** Yakamoz remains an XcodeGen-driven macOS app. The local sibling PositronicKit package is replaced by the public SwiftPM package URL, release-facing docs are updated in Yakamoz, and PositronicKit gains a companion-app link back to Yakamoz.

**Tech Stack:** Swift 6, XcodeGen, Xcode/macOS test destination, SwiftPM package resolution, Apache-2.0 licensing, GitHub SSH remotes.

## Global Constraints

- Yakamoz release remote: `git@github.com:phynics/Yakamoz.git`.
- PositronicKit public package URL: `https://github.com/phynics/PositronicKit.git`.
- Yakamoz license: Apache License, Version 2.0.
- Yakamoz remains a source release, not a signed binary distribution.
- Yakamoz remains a local, non-sandboxed, single-user macOS showcase app.
- Yakamoz must no longer require `../PositronicKit` for the normal public build path.
- Generated and local artifacts remain untracked: `Yakamoz.xcodeproj/`, `DerivedData/`, `.build/`, `.worktrees/`.
- Yakamoz and PositronicKit changes are committed separately in their own repositories.

---

## File Structure

- `/Volumes/Development/monad-project/Yakamoz/LICENSE`: new Apache-2.0 license text.
- `/Volumes/Development/monad-project/Yakamoz/project.yml`: replace local PositronicKit path package with public remote package on `main`.
- `/Volumes/Development/monad-project/Yakamoz/Makefile`: remove the sibling `../PositronicKit/Package.resolved` validation from `verify`.
- `/Volumes/Development/monad-project/Yakamoz/README.md`: update public clone/build instructions, PositronicKit links, license note, and source-release caveat.
- `/Volumes/Development/monad-project/PositronicKit/README.md`: add Yakamoz companion-app link.

### Task 1: Configure Yakamoz Release Remote

**Files:**
- Modify Git config only: `/Volumes/Development/monad-project/Yakamoz/.git/config`

**Interfaces:**
- Consumes: requested remote URL `git@github.com:phynics/Yakamoz.git`.
- Produces: `origin` remote for later push.

- [ ] **Step 1: Verify current remote state**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz remote -v
```

Expected before change: no output.

- [ ] **Step 2: Add origin remote**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz remote add origin git@github.com:phynics/Yakamoz.git
```

Expected: command exits `0`.

- [ ] **Step 3: Verify origin remote**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz remote -v
```

Expected output includes:

```text
origin	git@github.com:phynics/Yakamoz.git (fetch)
origin	git@github.com:phynics/Yakamoz.git (push)
```

### Task 2: Add Yakamoz Apache-2.0 License

**Files:**
- Create: `/Volumes/Development/monad-project/Yakamoz/LICENSE`

**Interfaces:**
- Consumes: selected license Apache-2.0.
- Produces: repository license metadata for public GitHub source release.

- [ ] **Step 1: Add Apache-2.0 license file**

Create `/Volumes/Development/monad-project/Yakamoz/LICENSE` using the standard Apache License, Version 2.0 text with copyright owner:

```text
Copyright 2026 Atakan DULKER
```

- [ ] **Step 2: Verify license text is present**

Run:

```bash
sed -n '1,20p' /Volumes/Development/monad-project/Yakamoz/LICENSE
```

Expected output starts with:

```text
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/
```

### Task 3: Switch Yakamoz To Public PositronicKit Package

**Files:**
- Modify: `/Volumes/Development/monad-project/Yakamoz/project.yml`
- Modify: `/Volumes/Development/monad-project/Yakamoz/Makefile`

**Interfaces:**
- Consumes: PositronicKit public package URL `https://github.com/phynics/PositronicKit.git`.
- Produces: XcodeGen project package config that resolves without a sibling checkout.

- [ ] **Step 1: Update `project.yml` package declaration**

Replace:

```yaml
  PositronicKit:
    path: ../PositronicKit
```

with:

```yaml
  PositronicKit:
    url: https://github.com/phynics/PositronicKit.git
    branch: main
```

- [ ] **Step 2: Update `Makefile` verification prerequisites**

Change the first line from:

```make
.PHONY: generate build test verify check-json-schema-pin
```

to:

```make
.PHONY: generate build test verify
```

Remove:

```make
POSITRONICKIT_RESOLVED = $(CURDIR)/../PositronicKit/Package.resolved
```

Remove the entire `check-json-schema-pin:` target.

Change:

```make
verify: check-json-schema-pin
```

to:

```make
verify:
```

- [ ] **Step 3: Confirm no sibling PositronicKit assumption remains in build files**

Run:

```bash
rg -n '../PositronicKit|POSITRONICKIT_RESOLVED|check-json-schema-pin' /Volumes/Development/monad-project/Yakamoz/project.yml /Volumes/Development/monad-project/Yakamoz/Makefile
```

Expected: no matches.

### Task 4: Update Yakamoz Public README

**Files:**
- Modify: `/Volumes/Development/monad-project/Yakamoz/README.md`

**Interfaces:**
- Consumes: remote dependency from Task 3 and Apache-2.0 license from Task 2.
- Produces: public-facing source release instructions.

- [ ] **Step 1: Update opening PositronicKit reference**

Replace the relative PositronicKit link:

```markdown
the shared [`PositronicKit`](../PositronicKit) agent runtime
```

with:

```markdown
the shared [`PositronicKit`](https://github.com/phynics/PositronicKit) agent runtime
```

- [ ] **Step 2: Update prerequisites**

Remove the sibling checkout prerequisite and add a source-release note:

```markdown
- **[XcodeGen](https://github.com/yonsei/XcodeGen)** (`brew install xcodegen`) — the
  `.xcodeproj` is generated from [`project.yml`](project.yml) and is not the source of truth.
- This repository is a **source release**, not a signed or notarized binary distribution.
  Build and run it locally from source.
```

- [ ] **Step 3: Add public clone instructions before build commands**

Insert before `All commands run from this directory`:

```markdown
Clone and enter the repository:

```bash
git clone git@github.com:phynics/Yakamoz.git
cd Yakamoz
```

`make generate` resolves [`PositronicKit`](https://github.com/phynics/PositronicKit)
through SwiftPM from its public GitHub repository.
```

- [ ] **Step 4: Add license section near the end**

Add:

```markdown
## License

Yakamoz is released under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
```

- [ ] **Step 5: Confirm no stale sibling checkout docs remain**

Run:

```bash
rg -n '../PositronicKit|sibling' /Volumes/Development/monad-project/Yakamoz/README.md
```

Expected: no matches.

### Task 5: Reference Yakamoz From PositronicKit

**Files:**
- Modify: `/Volumes/Development/monad-project/PositronicKit/README.md`

**Interfaces:**
- Consumes: Yakamoz public URL `https://github.com/phynics/Yakamoz`.
- Produces: cross-repo documentation link from PositronicKit to Yakamoz.

- [ ] **Step 1: Add companion app section after Quick Start**

Insert after the Quick Start import guidance:

```markdown
## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for
PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt
pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local
workspace state through an inspector drawer.
```

- [ ] **Step 2: Verify Yakamoz link exists**

Run:

```bash
rg -n 'Yakamoz|https://github.com/phynics/Yakamoz' /Volumes/Development/monad-project/PositronicKit/README.md
```

Expected: matches in the new companion app section.

### Task 6: Verify, Commit, And Report

**Files:**
- Read: both repository statuses.
- Commit: Yakamoz changes separately from PositronicKit changes.

**Interfaces:**
- Consumes: completed Tasks 1-5.
- Produces: clean committed release-prep changes and verification output.

- [ ] **Step 1: Generate Yakamoz project**

Run:

```bash
make -C /Volumes/Development/monad-project/Yakamoz generate
```

Expected: XcodeGen generation succeeds.

- [ ] **Step 2: Verify Yakamoz**

Run:

```bash
make -C /Volumes/Development/monad-project/Yakamoz verify
```

Expected: command exits `0` and reports a non-zero executed test count.

- [ ] **Step 3: Check Yakamoz status**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz status --short
```

Expected tracked changes include `LICENSE`, `Makefile`, `README.md`, `project.yml`, and this plan file if not already committed. Generated artifacts remain untracked/ignored.

- [ ] **Step 4: Commit Yakamoz changes**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz add LICENSE Makefile README.md project.yml docs/superpowers/plans/2026-06-30-yakamoz-initial-source-release.md
git -C /Volumes/Development/monad-project/Yakamoz commit -m "Prepare Yakamoz initial source release"
```

Expected: commit succeeds.

- [ ] **Step 5: Check PositronicKit status**

Run:

```bash
git -C /Volumes/Development/monad-project/PositronicKit status --short
```

Expected tracked changes include only `README.md`.

- [ ] **Step 6: Commit PositronicKit changes**

Run:

```bash
git -C /Volumes/Development/monad-project/PositronicKit add README.md
git -C /Volumes/Development/monad-project/PositronicKit commit -m "Reference Yakamoz companion app"
```

Expected: commit succeeds.

- [ ] **Step 7: Final status**

Run:

```bash
git -C /Volumes/Development/monad-project/Yakamoz status --short --branch
git -C /Volumes/Development/monad-project/PositronicKit status --short --branch
```

Expected: both working trees are clean. Yakamoz may be ahead of `origin/main` after the remote is added.
