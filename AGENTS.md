# Repository workflow

- Use the checked-in ManPageCatalog.xcodeproj; regenerate it only when project.yml changes.
- Native CI runs xcodebuild test -project ManPageCatalog.xcodeproj -scheme ManPageCatalog -destination 'platform=macOS' CODE_SIGN_IDENTITY="-". Preserve that integration gate and the required Metal toolchain installation. CodeQL resolves the installed Metal component before initialization and gives Xcode its explicit external toolchain path and identifier while retaining the default Swift toolchain.
- Keep manual .github/workflows/release.yml builds limited to release artifacts. Release publication is a separate authorized operation.
- Follow README.md for isolated extracted-app verification. Keep private catalogs, checkpoints, and terminal output out of public artifacts.
- Require successful native Swift analysis at the candidate revision; preserve the separate Python and Actions scans.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.
