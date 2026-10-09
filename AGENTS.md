# Repository workflow

- Use the checked-in ManPageCatalog.xcodeproj; regenerate it only when project.yml changes. When reviewing an Xcode Swift dependency PR, synchronize the authoritative project.yml version constraint with its reviewed project.pbxproj and Package.resolved update, then regenerate and verify through the established workflow before accepting it.
- Native CI runs xcodebuild test -project ManPageCatalog.xcodeproj -scheme ManPageCatalog -destination 'platform=macOS' CODE_SIGN_IDENTITY="-". Preserve that integration gate and the required Metal toolchain installation. CodeQL uses Xcode 26.3 on macOS 26; resolve and validate the installed external Metal compiler and linker before initialization and retain the real shader compilation.
- Keep manual .github/workflows/release.yml builds limited to release artifacts. Release publication is a separate authorized operation.
- Follow README.md for isolated extracted-app verification. Keep private catalogs, checkpoints, and terminal output out of public artifacts.
- Require successful native Swift analysis at the candidate revision; preserve the separate Python and Actions scans.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.
