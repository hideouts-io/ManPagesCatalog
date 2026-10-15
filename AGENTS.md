# Repository workflow

- Use the checked-in ManPageCatalog.xcodeproj; regenerate it only when project.yml changes. When reviewing an Xcode Swift dependency PR, synchronize the authoritative project.yml version constraint with its reviewed project.pbxproj and Package.resolved update, then regenerate and verify through the established workflow before accepting it.
- Native CI runs xcodebuild test -project ManPageCatalog.xcodeproj -scheme ManPageCatalog -destination 'platform=macOS' CODE_SIGN_IDENTITY="-". Preserve that integration gate and the required Metal toolchain installation. CodeQL uses Xcode 26.4.1 on macOS 26; resolve and validate the installed external Metal compiler and linker before initialization and retain the real shader compilation.
- Keep manual .github/workflows/release.yml builds limited to release artifacts. Release publication is a separate authorized operation.
- Follow README.md for isolated extracted-app verification. Keep private catalogs, checkpoints, and terminal output out of public artifacts.
- Require successful native Swift analysis at the candidate revision; preserve the separate Python and Actions scans.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.

# Project working defaults

These instructions apply only to this project and its canonical repository.

- Read `WORKSPACE.md`, the applicable `AGENTS.md` and `AGENTS.override.md` files, the actual `TODO.md`, project documentation, and the latest project checkpoint before making changes.
- Always verify the canonical checkout, Git root, current branch, `HEAD`, remote, upstream, attached worktrees, open pull requests, and staged, unstaged, and untracked files. Preserve all unrelated work.
- Do not start adapters, dependencies, installers, packaging, or CI work while an actionable TODO remains.
- Maintain durable project continuity during active work. At the beginning of a work session, load the latest project memory and checkpoint. At least once every hour while actively working, and again before ending or pausing, save a concise checkpoint in the existing project checkpoint or continuity location. Do not create duplicate planning documents or store credentials, secrets, signing material, device identifiers, raw backups, private logs, downloaded threat intelligence, personal information, or large command output in memory.

## Git and GitHub delivery

For normal Git and GitHub delivery of work implemented and verified in this project, the user grants standing authorization to:

- Stage only reviewed files or hunks belonging to the current task.
- Create focused commits with clear, conventional messages.
- Create and use a `codex/` feature branch when appropriate.
- Push the task branch to the verified GitHub repository.
- Create or update a pull request when review or CI is the safest delivery path, and mark a draft ready after implementation and required checks complete.
- Push follow-up fixes needed to make required pull-request CI checks pass.

Use a pull request by default for source, application behavior, packaging, workflow, dependency, security-sensitive, or substantial multi-file changes. A direct push is acceptable only on the correct non-protected task branch when it follows repository practice and does not bypass required review or branch protection.

Before every commit or push:

1. Confirm the canonical repository, branch, remote URL, upstream, `HEAD`, and outgoing diff.
2. Preserve unrelated staged, unstaged, and untracked work.
3. Stage explicit files or reviewed hunks; never use `git add .`, `git add -A`, or `git commit -a` in a dirty canonical checkout.
4. Inspect the complete staged diff.
5. Check that credentials, private evidence, device identifiers, personal data, local absolute paths, backups, logs, downloaded indicators, build caches, and private test artifacts will not enter Git history.
6. Run applicable tests, linting, documentation checks, packaging checks, and native UI checks.
7. Review the final diff for regressions, security issues, scope drift, generated-file mistakes, and unrelated changes.
8. Fetch and inspect the verified remote before integrating upstream changes; do not use a blind pull.
9. Push only the intended branch and verify that the remote revision matches the expected commit.
10. Inspect resulting GitHub checks and fix failures without weakening tests, assertions, security controls, or required gates.

If the canonical checkout contains overlapping or conflicting user work, preserve it and use an existing suitable review worktree or create a focused worktree from the correct committed base. Do not reset, clean, stash, discard, overwrite, or silently include unrelated changes.

This authorization does not cover merging a pull request, force-pushing or rewriting published history, deleting remote branches, creating tags or GitHub releases, publishing release artifacts, deploying a website or application, approving protected environments or publication jobs, changing branch protection/repository visibility/permissions/secrets/Actions settings, installing or broadening GitHub App access, or sending unrelated external messages or review responses. Ask separately before those operations.

Continue autonomously through implementation, verification, commit, push, pull-request creation or update, and CI repair within these boundaries. A successful pull request and passing CI do not authorize a merge, release, deployment, or publication.
