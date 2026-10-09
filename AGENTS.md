# Repository instructions

## Git and GitHub

- Verify the canonical checkout, applicable overrides, branch, origin, revision, index, and dirty files before Git changes. Preserve unrelated work; isolate conflicting work in a worktree.
- Use a focused codex/ branch for a reviewable change. Keep uncommitted work available for user review unless a commit is authorized.
- Commit, push, PR creation, merge, tag, release, deployment, visibility changes, and deletion require authorization covering the operation and target. Honor an existing scoped authorization; do not infer publication from implementation approval.
- Stage explicit paths or approved hunks, review the complete staged diff, and keep private evidence and secrets out of GitHub.
- Merge only after applicable checks and conversations are satisfied for the latest candidate revision. Preserve required checks and prefer merge commits over rebase or squash when compatible with repository rules.
- Pin external Actions to upstream-verified full commit SHAs. Keep PR jobs read-only except the scoped code-scanning upload permission; publishing jobs require the protected github-release environment.

## Repository workflow

- Use the checked-in ManPageCatalog.xcodeproj; regenerate it only when project.yml changes.
- Native CI runs xcodebuild test -project ManPageCatalog.xcodeproj -scheme ManPageCatalog -destination 'platform=macOS' CODE_SIGN_IDENTITY="-". Preserve that integration gate and the required Metal toolchain installation.
- Keep manual .github/workflows/release.yml builds limited to release artifacts. Release publication is a separate authorized operation.
- Follow README.md for isolated extracted-app verification. Keep private catalogs, checkpoints, and terminal output out of public artifacts.
- Require successful native Swift analysis at the candidate revision; preserve the separate Python and Actions scans.
