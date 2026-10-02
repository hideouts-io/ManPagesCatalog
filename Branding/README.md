# ManPagesCatalog brand assets

The cyan/blue open book and terminal prompt come from the supplied master sheet in `source/master-sheet.png`. Individual assets were reconstructed with the built-in image generation tool, then sized and converted with macOS `sips` and `iconutil`. They are raster reconstructions, not exact crops or vector originals. The original sheet is preserved unchanged; `source/prompts.json` records the prompts and selected outputs.

The separately approved GitHub artwork is preserved unchanged in `source/social-preview-approved.png` (1774 × 887). The upload copies in `social/` resize that attachment without changing its composition, text or artwork.

## Files to use

| Purpose | File | Dimensions / format |
| --- | --- | --- |
| macOS application icon | `app/ManPagesCatalog.icns` | Multi-resolution ICNS, 16–1024 px |
| Dark icon | `app/icon-dark-1024.png` | 1024 × 1024; smaller sizes included |
| Light icon variant | `app/icon-light-1024.png` | 1024 × 1024 |
| Standalone logo mark | `logos/logo-mark.png` | 1024 × 1024 |
| Horizontal logo and wordmark | `logos/wordmark-dark.png` | 1800 × 600 |
| GitHub social preview | `social/github-social-preview.jpg` | 1280 × 640; 219,034 bytes |
| Website hero | `web/hero.jpg` | 1600 × 800 |
| Website social/Open Graph image | `web/og-image.jpg` | 1200 × 630 |
| Website icons | `web/icon-*.png` | 16, 32, 48, 180, 192 and 512 px |

Icons retain transparent outer corners. The logo mark, wordmark and banners use an opaque navy background to keep edges and text clean. PNG copies of the banners are included for lossless editing; use the smaller JPEG copies for upload and website delivery. Do not distort the aspect ratios or reuse the presentation sheet as a finished icon.

## Application

`ManPageCatalog/Resources/AppIcon.icns` is the runtime copy of `app/ManPagesCatalog.icns`. `CFBundleIconFile` in `project.yml` and the generated Info.plist points to `AppIcon`. The welcome screen uses the application icon; the README uses the horizontal wordmark. The light icon is an optional asset, not an automatic appearance-dependent replacement.

## GitHub

The repository social preview uses **`social/github-social-preview.jpg`**. To replace it, use **Settings → Social preview → Edit → Upload an image**. It meets the documented 1280 × 640 recommendation and under-1-MB limit. The lossless PNG is larger than the upload limit. See [GitHub's social preview requirements](https://docs.github.com/en/enterprise-cloud%40latest/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview).

The preview describes the current macOS product: searching manuals, reading documentation, in-page Find, and PDF export. Its illustrated terminal panel is artwork, not a screenshot of the app.

## hideouts.io

The website pack contains `web/` and `logos/`. Place their contents under your chosen public asset directory, preserve subdirectories, and adapt `web/head.html` to that deployed URL. Use the hero as a feature image, the wordmark for headers on a dark surface, and the PNG icons for favicons and touch icons. Supply meaningful alt text such as “ManPagesCatalog — searchable manuals for macOS”; use empty alt text when an adjacent label already identifies a decorative logo.

These files prepare the website assets only; the live hideouts.io site is unchanged. Updating the GitHub repository's social preview is separate from deploying a website or publishing a release.
