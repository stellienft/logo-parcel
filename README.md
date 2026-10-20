# Logo Parcel

<img src="resources/AppIcon.png" alt="Logo Parcel app icon" width="160">

**A straightforward logo handoff tool for Mac.**

Created by [Stellio Creative Labs](https://stellio.com.au) · [GitHub / @stellienft](https://github.com/stellienft)

Logo Parcel takes your approved logo artwork and packages the versions your client needs: colour variations, RGB and CMYK files, organised folders, a ZIP archive and a visual HTML guide.

**Status: development preview, version 0.4.0.** The source is public and open-source. A ready-to-install public download has not been published. The current build targets Apple silicon and uses `/usr/bin/python3`; a self-contained, signed and notarised public build is still required.

## Screenshots

A look at the four-step workflow in version 0.4.0, using fictional example artwork.

| Add your artwork | Choose export options |
| --- | --- |
| ![Add artwork](screenshots/01-artwork.png) | ![Export options](screenshots/02-export-options.png) |
| **Review the actual files** | **Name and save your package** |
| ![Review exports](screenshots/03-preview.png) | ![Name and save](screenshots/04-save.png) |

[View the full-size screenshot gallery](screenshots/README.md).

## What it does

- Start with a full logo; optionally add a symbol and wordmark.
- Add named variations: horizontal, vertical, with slogan, without slogan, social avatars or your own label.
- Choose SVG, PNG, JPG, PDF, EPS and PDF-compatible AI exports.
- Choose digital (RGB), print (CMYK) or both.
- Generate full-colour, black, white, grayscale, inverted and custom solid versions.
- Review visual previews and select the exact files to deliver.
- Save an organised folder and ZIP, with a branded, offline HTML logo library.
- Keep original artwork unchanged. All processing takes place locally.

## How to use it

### 1. Save your finished artwork

Save your logo from VectorCraft first. SVG or `.vectorcraft` are good starting points; PDF, EPS and AI files can also be opened. Prepare the symbol, wordmark and other lockups as separate files or artboards. Logo Parcel packages approved designs; it does not invent lockups or automatically separate the parts of a logo.

### 2. Add your artwork

Click **Add full logo**. Add a symbol or wordmark if needed. Click **Add variation** for additional items and give each one a descriptive name, such as “Vertical lockup — no slogan”. For files with several artboards, select the relevant artwork from the thumbnails.

### 3. Choose your exports

Choose **Digital only**, **Print only** or **Both**. Select file formats and colour versions. Open **More options** for raster widths, clear space and other settings. Incompatible format/mode combinations are excluded automatically.

### 4. Review the actual files

Click **Build visual preview**. Enlarge a preview to inspect it, filter the grid and uncheck files you do not want. White artwork is displayed against a dark tile so you can see it.

### 5. Name and save

Choose a package name and save folder, then click **Export**. Existing packages are kept with numbered filenames. The files delivered are the exact bytes reviewed in the preview.

### 6. Hand the package to your client

Send the ZIP. After extracting it, the client opens **START-HERE.html** to browse the logo library. It contains previews, format links, digital/print filters and a variation search box. Keep that HTML file beside the artwork folders so its links work. It needs no account or internet connection; the creator links are external.

## File support and limits

| Format | Digital RGB | Print CMYK | Notes |
| --- | --- | --- | --- |
| SVG | Yes | No | Scalable web artwork; optional text outlining |
| PNG | Yes | No | Transparent backgrounds |
| JPG | Yes | Yes | White variants use a black background |
| PDF | Yes | Yes | VectorCraft export; check printer requirements |
| EPS | Yes | Yes | May flatten effects/transparency |
| AI | Yes | Yes | PDF-compatible output, not Adobe's full native editing data |

CMYK conversion uses VectorCraft's colour settings. Printed appearance depends on the output profile, paper and printer. Automatic monochrome recolouring also recolours white filled shapes; use real cutout paths or approved monochrome artwork where needed. Check font substitutions, images and complex effects in the previews and export notes.

The current version has no custom filename templates, saved presets, live connection to an unsaved editor document, Pantone workflow or print-profile picker.

## Build locally (development)

Requirements: macOS, Apple Command Line Tools with Swift, Python 3, and the official VectorCraft 0.13.1 macOS CLI release package. The present interface launches `/usr/bin/python3`; this dependency must be replaced by a bundled runtime before public release.

1. Download and extract the official [VectorCraft CLI release](https://github.com/storytold/vectorcraft/releases/tag/v0.13.1), including its licence and notice files.
2. Run the build script, pointing it at the extracted directory:

```sh
bash scripts/build-local.sh /absolute/path/to/vectorcraft-cli-0.13.1-macos-universal
```

The app is written to `dist/Logo Parcel.app`. It is ad-hoc signed for local development only. Building on a Mac does not automatically create a universal binary or a public distribution signature.

## Project structure

- `src/LogoParcel.swift` — native SwiftUI interface and guided workflow.
- `src/packager.py` — VectorCraft export orchestration, preview verification and packaging.
- `src/htmlguide.py` — self-contained client HTML guide.
- `resources/branding.json` — creator website link.
- `scripts/build-local.sh` — local development build.
- `RELEASE_CHECKLIST.md` — remaining public-distribution steps.

Do not commit the generated app, engine binary, test output, customer logos, certificates or credentials. Use GitHub release assets for distributable application packages.

## Credits and licensing

Original app and guide by Stellio Creative Labs. Export rendering uses [VectorCraft](https://github.com/storytold/vectorcraft), with its supplied MIT/Apache and third-party notices preserved in distributed engine packages. Logo Parcel is independent of ArtCraft.

Logo Parcel's original source is available under the [MIT License](LICENSE), copyright © 2026 Stellio Creative Labs. VectorCraft and other dependencies retain their own licences and notices.

## Feedback

Use [GitHub Issues](https://github.com/stellienft/logo-parcel/issues) to report a problem. Include your app version, macOS version, source format and export settings. Only attach artwork you are permitted to share.
