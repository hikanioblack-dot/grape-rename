# Grape Rename 1.0.10

A native batch renaming app for macOS Tahoe 26 or later and Apple Silicon.

The version is available in Help → Grape Rename Version and Grape Rename → About Grape Rename. Both open the system panel with the icon, version and build number. Versions follow 1.0.x, where x matches the build number; the current build is 10. Values come from Info.plist.

## Usage

Install from Grape-Rename.dmg by dragging Grape Rename.app onto Applications. Choose files or a folder in the center of the main window, or drop them from Finder. Choosing a folder loads regular visible files directly inside it; subfolders and symbolic links are skipped. Dropping onto an existing list adds files and excludes repeated paths.

In the left sidebar, set the common name, separator, starting number (1 by default) and digit count (4 by default). An empty common name produces names such as 0001.txt and 0002.pdf. Keep Original Name produces, for example, Holiday_0001_IMG_1234.jpg. File extensions are preserved.

Sort by name, modification date, creation date, size or extension. The arrow reverses the direction. For manual order, drag rows or select a row and use the arrows below the list. In compact and thumbnail lists, a purple line shows the insertion point: the upper half of a row inserts before it, the lower half after it. New names always follow the list from top to bottom. Right-click to remove a file from the list or reveal it in Finder.

Rows show thumbnails through Quick Look. If a system thumbnail is unavailable, text formats receive a text thumbnail and other files an extension label. Select a row and press Space for Quick Look. Arrow keys switch files; pressing Space again closes the window. Double-click and the eye button also open previews. Space remains a normal character while typing in a text field.

Click Rename. Undo in the toolbar or ⌘Z restores the last rename, including operations performed before restarting the app. History shows the changes. Undo proceeds in reverse order: the most recent operation first. Files are checked by inode, size, creation date and modification date. If a file was moved or changed, the operation is refused. ⌘O chooses files; ⇧⌘O chooses a folder; ⌘I reveals the preview and metadata sidebar.

Saved presets include the prefix, separator, numbering, original-name option, find/replace and EXIF settings. Save, update, delete and reuse them. Find and replace operates literally on the original filename stem without changing the extension. Turn numbering off for simple text replacement.

Grid thumbnail size is adjustable. Grid order goes left to right, then top to bottom; list order goes top to bottom. Manual ordering is available in both.

EXIF naming uses DateTimeOriginal without substituting the modification date. Date formats are fixed and preserve the local capture time recorded in EXIF. Photos without EXIF receive no date and sort after dated photos. Metadata is read-only: general file properties, image properties, EXIF/TIFF/GPS when available and PDF information.

The interface language follows your macOS settings automatically. History and presets are stored locally at ~/Library/Application Support/Grape Rename/state.json. Pending operations are journaled before renaming. At startup, completed operations are added to history; partial operations restore the original names.

## Tools: duplicates and similar photos

The **Tools** menu offers two separate searches. Files from the main list are selected initially; you can choose other files or folders in the search window. Folder scans can include subfolders. Hidden files and symbolic links are skipped; multiple hard links to the same file count once.

**Exact duplicates:** size filtering, streaming SHA-256 and byte-for-byte verification. Names, extensions and dates may differ.

**Similar photos:** a perceptual image hash combined with Apple Vision, with strict, balanced and broader matching. This helps locate resized, recompressed and related images, but does not prove identical content. Each file is compared with its group's first image; similar photos must be reviewed manually and cannot be deleted automatically as exact copies.

Search runs locally in the background, reports progress and can be stopped. Unreadable and corrupt files are listed separately. One file in each group is marked **Keep**, and you can change it. Nothing is selected initially. In exact search, **Move All Copies to Trash…** selects every file except those marked **Keep**, then asks for confirmation with the file count. To remove individual files, check their boxes and click **Move Selected to Trash…**.

**Remove from Batch** excludes selected files from renaming without changing the files on disk. **Move to Trash** requests confirmation and checks for changes since the scan. Restore trashed files in Finder; rename undo does not restore them. The displayed size is the sum of selected file sizes, not guaranteed reclaimed disk space.

The main window opens immediately. Prefix, numbering and the naming example stay visible; presets, find and replace and EXIF settings are in collapsible **Advanced** sections at the bottom of the left sidebar.

## Dates and protection

The app renames a file within its original folder using a system rename call; it does not rewrite contents. It checks source changes and name conflicts before the operation. Existing files are never overwritten. Name swaps use temporary names, with rollback on failure. After renaming, modification time including nanoseconds, creation time, size and inode are checked.

The files' modification dates are preserved. Renaming may change the parent folder's modification date and system metadata change time (ctime); this is normal macOS behavior.

## Text in images

Open **Tools → Find Text in Images…** to scan images or folders locally with Apple Vision. No metadata is needed. Only the first page/frame of multipage or animated images is scanned. Unreadable and corrupt images are listed separately.

Switch between **With Text**, **Lots of Text**, **No Text Detected** and **All Images** without rescanning. Adjust the minimum non-whitespace character and line counts for Lots of Text. Search for a word or phrase without case sensitivity. The right sidebar shows a preview and recognized text, with a copy button.

Text does not prove an image is a screenshot. Document photos also contain text, and small or blurry text may be missed. No Text Detected is not a guarantee that an image contains no writing.

Check files and use **Selected Files…** to copy or move them to a folder, or move them to Trash. Existing destination names are never overwritten. **All Matches to Trash…** targets only the current filter and query results and asks for confirmation with the count. Unlike duplicate search, no copy is protected: these are the original matching images. Files are checked for changes before actions. Restore trashed files in Finder; rename history does not undo moving or deleting images.

Scanning runs in the background and can be stopped. Optional local caching stores recognized text; disable it or use **Clear Cache** to delete it. Files and text are never uploaded. Scanning preserves image contents and modification dates.

## Building

Requires Command Line Tools with Swift 6.3 and the macOS 26 SDK. In Terminal:

```sh
zsh build.sh
```

The script creates the app, ZIP, DMG and checksum in dist/, applies a local ad-hoc signature and runs tests. All source code is available. The build uses no third-party libraries, network or telemetry. This is a local Apple Silicon build, without Developer ID signing or Apple notarization for distribution to other computers. The DMG contains the app, an Applications link and installation instructions. The packaged DMG is available in GitHub Releases.

## Checks

The built-in --self-test checks renaming eight files, preserving bytes and metadata, undo, name swaps, conflict refusal and protection against files changing after selection. It also covers mixed file/folder import; duplicate, hidden-file, symbolic-link and subfolder exclusions; sorting, manual order and naming templates.

For testing, create new synthetic samples with --make-fixtures PATH, --make-duplicate-fixtures PATH or --make-text-fixtures PATH. They include images with and without EXIF, documents, media and text images. Generators do not overwrite an existing folder; personal files are not needed for testing.

## Interface update

The header shows only the folder name on one line, truncating long names and exposing the full name in a tooltip. The Add menu has a text button. Three views are available: compact rows without thumbnails (24 pt), a thumbnail list and a grid. Metadata is in the right sidebar with an embedded Quick Look preview. The sidebar updates when selecting and renaming files and can be hidden. Space still opens a separate full-size preview. Photos, PDFs and media use native previews.
