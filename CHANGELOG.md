# Changelog

## 1.1.2 — 2026-10-16

Includes changes from the unpublished 1.0.11 local build.

- Background file import with progress, cancellation and stale-result protection; failed imports preserve the previous batch.
- Prevent duplicate file chooser dialogs while one is already open.
- Correct singular/plural wording in OCR Trash confirmations.

- Bounded concurrent OCR and more efficient batch updates after rename/undo.
- Protect numbering previews against invalid and overflowing starting values.
- Consolidated media tools, clearer OCR selection actions and frozen confirmation snapshots.
- File information/history in File, view commands in Window, and a compact Cache menu.

## 1.0.10

- On-device image OCR in Tools, independent of EXIF metadata.
- Text, text-density, no-text and phrase filters with image previews and recognized text.
- Optional local OCR cache with invalidation and a clear-cache action.
- Copy or move selected images to a folder without overwriting existing names.
- Confirmed selected/all-filtered-results Move to Trash with changed-file protection.
- OCR, cache, filtering, export and deletion-safety regression tests.

## 1.0.9

- Exact duplicate results offer Move All Copies to Trash with confirmation, preserving the chosen Keep file in every group.
- Clearer checkbox guidance and a separate Move Selected to Trash action.
- Regression coverage for custom kept files across multiple duplicate groups.

## 1.0.8

- Tools menu with exact duplicates (size, streamed SHA-256, byte verification).
- Similar photos using perceptual hashing and Apple Vision, with adjustable matching.
- Cancellable background scans of files and folders, optional recursive search, progress and skipped-file reports.
- Group previews, protected kept file, exclusion from the rename batch and confirmed Move to Trash.
- Main window opens immediately with a centered file chooser.
- Presets, find and replace and EXIF in collapsible Advanced sidebar sections.
- Tests for scanning, file preservation, changed-file guards, cancellation and similar-image detection.

## 1.0.7 — First public release

- Native macOS Tahoe interface.
- Batch naming, sorting, manual order and saved presets.
- Compact rows, thumbnail list and adjustable grid.
- Quick Look on Space, inline previews and file metadata.
- EXIF capture dates and literal find and replace.
- Persistent history with undo after restarting.
- File content and modification timestamp preservation.
- New Grape icon and version entry in Help.
- Downloadable DMG for Apple Silicon Macs running macOS 26+.

We will keep updating Grape Rename and adding features. A Windows edition is planned.
