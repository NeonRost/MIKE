# MIKE

MIKE – Mike's Toolbox. A macOS window app (SwiftUI, macOS 13+) that bundles
twenty utilities plus a Setup section, grouped in the sidebar as:

- **Web**: video download, TikTok direct link
- **Text**: article text extraction, image text recognition, text file
  merging, character encoding conversion
- **Images**: quick edit (straighten/crop/format convert/strip metadata),
  image stacking, image format conversion, image metadata viewing/editing,
  embedded-block viewing/editing
- **Video**: video concatenation, video trimming (including an optional
  crop)
- **Audio**: audio tag editing, audio track splitting
- **Files**: file hash checking, batch renaming, file info inspection,
  duplicate finding, archive compression (ZIP/TAR.GZ)

Setup is pinned below the categories rather than sitting inside one — it is
not one of Mike's tools, just where their external dependencies get checked
and installed.

The Xcode project is generated from `project.yml` with XcodeGen and is committed
to the repository. Regenerate with `xcodegen generate` after changing
`project.yml`. The project is an open source repository on GitHub, licensed
under the GPLv3.

## Standing rules

### External tools are never bundled

`yt-dlp` and `ffmpeg` are **not** shipped inside the app bundle, and this is not
to be "fixed" later. Two reasons:

- yt-dlp breaks whenever a site changes and has to stay current through the
  user's package manager; a bundled copy would be stale within weeks.
- Every bundled executable would have to be signed and notarized along with the
  app.

Instead the app locates them on the system. Note that apps launched from the
Finder do **not** inherit the shell's `PATH`, so the search must probe absolute
paths explicitly — never rely on the environment. The search order is:

1. a user-supplied path (takes precedence, so a newer build can override an old
   one found in a standard location)
2. `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`

A candidate only counts as valid once it actually runs (`yt-dlp --version`,
`ffmpeg -version`) — an executable bit alone is not enough, because quarantined
or architecture-mismatched binaries pass that check and then fail at use.

Tool status is re-checked when the window becomes active again, not only at
launch: users install the tools in Terminal while MIKE is already running.

Sections whose tools are missing are disabled up front with a pointer to the
Setup section — never a failure that only appears after the user starts an
operation.

Homebrew itself is probed too (`ToolLocator.locateHomebrew`), but it is
deliberately **not** a `Tool`: MIKE never runs it and works without it. It is
checked only so Setup can tell whether the `brew install` line it offers would
work, and offer Homebrew's own installer when it would not. MIKE never executes
that installer — it is text to copy, nothing more.

The section is called **Setup** in the UI, not "Tools": it is not one of Mike's
tools but the place to check and install what they need, which is also why the
sidebar pins it below the categories instead of listing it inside one. The
code-side names (`Tool`, `ToolRegistry`, `ToolsView`) still refer to the
external tools themselves and stay as they are.

### The app is not sandboxed

Required in order to launch external binaries and write to user-chosen folders.
Do not add an App Sandbox entitlement.

This also settles the question that comes up around WKWebView in Extract
Article: `com.apple.security.network.client` ("Outgoing Connections") only
means anything **inside** a sandbox. Without the sandbox there is nothing to
grant, and switching the sandbox on to add it would break Download and Combine
Videos. Hardened Runtime is on and does not interfere — WebKit runs JavaScript
in its own process.

### Bundled JavaScript

`MIKE/Resources/Readability.js` and `Extraction.js` are **resources, not
source**. `project.yml` declares `MIKE/Resources` with
`buildPhase: resources`, and the main `MIKE` source entry excludes that folder
so nothing is added twice. If they ever land in Compile Sources the build still
succeeds and the feature fails at runtime, so check
`Contents/Resources/*.js` in the built bundle after touching the file list.

`Readability.js` is third-party (Apache 2.0) and keeps its own header — never
give it a GPL header. Failures inside `Extraction.js` report a machine-readable
`reason`, never a sentence, so the message the user sees is translated on the
Swift side.

### User input never reaches a process unchecked

The download URL is handed to `yt-dlp` as an argument, and yt-dlp reads anything
starting with a dash as an option — including `--exec`, which runs shell
commands. Two defences, both required:

- `WebURL.isValid` **parses** the input and demands an `http`/`https` scheme
  with a host. It is a security check, not a formatting nicety — do not relax it
  to a pattern match.
- `DownloadRunner` puts `--` immediately before the URL so option parsing ends
  there. Verified against the real yt-dlp: without it, `--version` as the
  "URL" is executed as an option.

Any new place that puts user text into a process argument needs the same
treatment. Paths coming from the open/save panels are absolute and therefore
safe, but a value the user typed is not.

The Metadata section hands both file paths and typed field values to
`exiftool`. The values are folded **inside** a single argument
(`-Copyright=<value>`), so a leading dash in the value cannot be read as an
option; and `MetadataWriter` still puts `--` before the file name, the same
end-of-options guard the download URL gets. `WebURL.isValid` does **not** apply
here — it is a URL parser, not a general argument sanitiser. The only typed
values that are range-checked are the GPS coordinates, parsed as numbers and
clamped to ±90 / ±180 before they become arguments.

### Long-running processes are cancellable

`ProcessRunner.stream` hands the live `Process` to the caller via `onStart` and
registers it centrally; `ProcessRunner.terminateAll()` runs from
`applicationWillTerminate` so nothing outlives the app. Sections that start one
show a Cancel button while it runs.

A cancelled run is **not** an error: it is reported in the neutral status
colour, and `DownloadRunner` deletes the `.part`, `.ytdl` and `.part-Frag*`
files belonging to the destinations *that run announced* — never a blanket
sweep of the folder, where another download may be in progress.

### Process invocations are frozen

The `yt-dlp` and `ffmpeg` command lines were carried over verbatim from the
original Python implementation, including argument order and the download
profiles per host. They are proven in practice — do not "clean them up".

### Download: audio extraction and probed quality

Two additions on top of the frozen video profiles above, both purely
additive — the default path (checked "Best available quality", video mode)
runs the exact same `-f`/`--postprocessor-args` invocation as before.

**Audio-only (`-x`)** reuses the existing progress/cancel/error machinery
completely unchanged: `"[ExtractAudio]"` was already in
`DownloadRunner.postprocessMarkers`, so the switch to "Converting…" once
yt-dlp starts transcoding needed no new code. The format menu label and the
value yt-dlp wants differ exactly once — there is no `ogg` literal, only
`vorbis` (verified against `yt-dlp --help`), which is what actually produces
the `.ogg` file. `AudioFormat.ytDlpValue` is where that translation happens;
the picker still shows "OGG".

**"Best available quality" is unchecked to get a real number, never a
promise.** yt-dlp's `-x` transcodes whatever audio stream it grabbed to any
bitrate you tell ffmpeg to target, even one higher than the source ever had —
the file gets bigger, not better. Rather than let the UI imply a video is
downloadable at 320 kbit/s when the source only offers 128, unchecking "Best
available quality" runs `FormatProbe` (`yt-dlp -j --no-warnings
--no-playlist`) to ask what this exact URL actually offers, and the picker
that appears is built only from that real list — a concrete bitrate or
height MIKE never invented. Checked (the default) skips the probe entirely
and keeps today's original unconstrained behavior: `--audio-quality 0` for
audio, `profile.format` untouched for video.

One probe result serves both pickers. `-j`'s JSON already lists every
format — audio-only entries (`vcodec == "none"`) and video-only entries
(`acodec == "none"`) — in a single call, so `DownloadView` caches one
`FormatProbeResult` per URL and switching the "Audio only" toggle after a
probe re-uses it instead of re-querying yt-dlp. A probe is invalidated by
simple string comparison against the live URL field at the moment it
*completes*, not when it started — editing the URL mid-probe drops that
now-stale answer rather than applying a different video's numbers, and the
UI falls back to a "check again" prompt rather than auto-re-probing on every
keystroke.

`FormatProbe`'s JSON parsing goes through `NSNumber` rather than `as? Int` /
`as? Double` directly on the decoded `Any`. Verified directly: a JSON
literal with no decimal point (`"height": 1080`) bridges to *both* `Int` and
`Double`, but a fractional one (`"abr": 128.612`) only bridges to `Double` —
`as? Int` on it fails outright instead of truncating. Going through
`NSNumber.intValue`/`.doubleValue` reads either shape correctly regardless
of which fields happen to carry a decimal point on a given source.

Capping video quality reuses the existing per-host `DownloadProfile` instead
of building a parallel selector: `cappedFormat` is a closure stored
alongside the frozen `format` string, one per profile shape (`recode`,
`rewrap`), producing the same selector with `[height<=N]` spliced into each
`bv`/`b`/`best` clause — never into the `ba[ext=m4a]` audio clause, which has
no height. `DownloadMode.video`'s `maxHeight` is `nil` on the default path,
so `profile.format` itself is never touched or replaced.

### Trim Video: duration from ffmpeg, playability from AVFoundation — never mixed up

The two questions "how long is this file" and "can this app preview it" are
answered by two completely different systems, verified directly rather than
assumed to agree:

- **Duration always comes from `ffmpeg -i`'s own `Duration:` line**
  (`VideoTrimmer.duration`, the same probe-banner technique
  `VideoConcatenator.layout` already uses for codec info), never from
  `AVAsset`/`AVURLAsset`. Proven necessary, not just simpler: for a real AVI
  file, `AVURLAsset(url:).load(.duration)` throws `AVFoundationErrorDomain
  Code=-11829 "Cannot Open"` — AVFoundation cannot read a duration out of a
  container it cannot open at all, which has nothing to do with ffmpeg's own,
  entirely separate AVI demuxer being able to read the exact same file fine.
  Sourcing duration from ffmpeg means it works identically for every accepted
  format, including the ones the preview can't show.
- **Preview availability is checked at runtime, not guessed from the file
  extension.** `TrimVideoView.load(_:)` calls `AVURLAsset(url:).load(
  .isPlayable)` and shows the "no preview" hint only if that call throws or
  returns `false` — verified directly that it does throw for AVI on this
  system rather than returning `false` cleanly, which is why the call is
  wrapped in `try?` rather than a plain `try`. A hardcoded "these extensions
  never preview" list would have been both less accurate (some `.mkv`/`.wmv`
  files genuinely are playable, depending on the codec inside) and unverified.

The trim itself (`-ss <start> -to <end> -i <input> -c copy <output>`, `-ss`
before `-i` for speed) runs identically regardless of whether the preview
loaded — the "no preview" hint leaves the Start/End fields and the Trim
button fully usable, only the `AVPlayerView` is swapped for a text hint.
Verified end-to-end with a real AVI: ffmpeg trims it correctly even though
`AVPlayer` never displays a frame of it.

The timeline's two markers read drag position from a *named* SwiftUI
coordinate space (`.coordinateSpace(name: "timeline")` on the containing
`GeometryReader`, `DragGesture(coordinateSpace: .named("timeline"))` on each
marker) rather than each marker's own local frame or a translation-from-
drag-start delta. A marker is a 14pt circle; its own local coordinate space
only ever spans those 14 points, useless for computing where across the
*whole* track a drag landed. Reading `value.location` against the shared
named space gives an absolute position on the full timeline regardless of
which marker the gesture happens to be attached to — simpler here than Quick
Edit's anchor-preserving delta math, because a single point marker has no
opposite edge that could drift.

### Deliberate departures from the original Python app

These were decided on purpose and are not parity bugs to be "fixed":

- **Natural sort.** Folder contents are ordered with `localizedStandardCompare`,
  the way the Finder orders them, so `page2` comes before `page10`. The
  original sorted lexicographically.
- **Collision protection.** `combined.jpg` and `combined.mp4` are never
  overwritten; a second run writes `combined (2).jpg`. The folder scan
  therefore has to skip those variants too — see `isOutput` in `ImageStacker`
  and `VideoConcatenator`, otherwise a later run would eat its own output.
- **Explicit output folder.** Both combine sections have a "Save to" row. In
  folder mode it is preset to the chosen folder, which reproduces the old
  behaviour of writing next to the sources, but it can be redirected.
- **Combining refuses mismatched videos.** ffmpeg's concat demuxer exits 0 even
  when inputs disagree on codec, resolution, frame rate or audio, and silently
  produces a broken file. `VideoConcatenator.preflight` compares the streams up
  front and the section reports what differs instead.

### The `_original` backup is never overwritten

Editing or removing metadata leaves exiftool's default backup —
`<name>.<ext>_original` in the same folder — as the untouched original. The
trap is the **second** run: exiftool's own behaviour when a `_original` already
exists is undocumented, and letting it recreate the backup would replace the
real original with the already-edited copy. So `MetadataWriter` decides in
Swift: no backup yet → run plain and let exiftool create it; a backup already
there → add `-overwrite_original` so exiftool edits in place and leaves the
existing `_original` alone. The UI confirms this first and reports which of the
two happened. Do not "simplify" this to always passing (or never passing)
`-overwrite_original`.

Reading metadata is separate and needs no external tool: it goes through
ImageIO (`CGImageSourceCopyPropertiesAtIndex`), so the Metadata section lists an
image's contents whether or not exiftool is installed, and only the edit/remove
controls depend on it — the same "optional tool greys out part of a section"
shape as cwebp in Convert Format.

### The Embedded section is complementary to Metadata

Embedded shows the text blocks ImageIO does **not** expose and that Metadata
therefore cannot: PNG `tEXt`/`zTXt`/`iTXt` chunks, XMP packets, and other
non-EXIF blocks. `EmbeddedExifReader` deliberately excludes the groups Metadata
already shows (EXIF, GPS, IPTC, standard TIFF IFDs) so the two never show the
same thing twice. A PNG `eXIf` chunk is noted by size only — its decoded EXIF is
Metadata's job.

- **PNG reading is native**, in `PNGChunkReader`: the chunk structure is parsed
  straight from the binary (no library, no exiftool), `zTXt`/compressed `iTXt`
  are inflated with the system `Compression` framework (strip the 2-byte zlib
  header → raw DEFLATE). This is the always-available path and it preserves the
  exact keyword case, which exiftool normalises. XMP and non-PNG formats are
  read through exiftool (`-j -G1 -struct`); without exiftool those are limited,
  the same greying-out shape as everywhere else.
- **Writing goes through exiftool**, but exiftool refuses to write PNG keywords
  it does not already know (`prompt`, `workflow`, custom keys — it answers "Tag
  not defined"). `EmbeddedMetadataWriter` therefore generates a temporary
  `-config` that registers each keyword as a writable `PNG::TextualData` tag.
  Redefining a built-in keyword like `parameters` there is harmless, and the
  config writes the exact lowercase keyword the AI tools expect. **This config
  step is load-bearing — do not remove it thinking a plain `-PNG:key=` will
  work.**
- **JSON values are strings.** A ComfyUI `workflow` is stored as a plain chunk
  string; MIKE pretty-prints a display copy but keeps the raw string and writes
  it back unchanged unless the user edits it, so a value is never silently
  reformatted on disk.
- **The `_original` protection is shared, not reimplemented.** Both writers go
  through `ExifToolWrite.run`, which owns the backup rule, the `--` guard and
  the result parsing. Change that behaviour in one place only.
- **A huge `workflow` must not freeze the view.** Long values are collapsed by
  default and the drawn text is capped (`RowView.displayCap`); the full value
  stays in the row for editing and copying. A single SwiftUI `Text` of tens of
  thousands of characters janks on layout, so never draw the whole value.
- **Typed keys are validated** by `EmbeddedMetadataWriter.isValidKey`: they must
  start with a letter or digit and contain only letters, digits and hyphens.
  That blocks a leading-dash option such as `-all=` from being entered as a key
  and keeps the generated Perl config free of any significant character. A file
  whose existing keyword falls outside that set is shown read-only rather than
  made editable.

### Read Image Text reads one column, top to bottom

`TextRecognizer` runs `VNRecognizeTextRequest` (`.accurate`, automatic language
detection) and reconstructs paragraph and line structure itself — Vision hands
back one observation per **line**, never a paragraph.

- **EXIF orientation must be read and passed explicitly.**
  `ImageConverter.load(from:)` hands back the raw, un-rotated `CGImage` — fine
  for format conversion, but Vision needs the real orientation to lay out lines
  correctly. `TextRecognizer.orientation(from:)` reads it via ImageIO
  (`kCGImagePropertyOrientation`, the same property `ImageMetadata` already
  reads) and it goes into `VNImageRequestHandler(cgImage:orientation:)`.
  Skipping this scrambles the reading order on any photo taken in portrait —
  verified against a real rotated test image: tagging the wrong EXIF value
  produced an exactly-180°-reversed reading order, tagging the correct one
  reproduced the upright result byte for byte.
- **One reading column, deliberately.** Lines are sorted top-to-bottom,
  left-to-right and grouped into paragraphs by vertical gap
  (`TextRecognizer.reconstruct`). Vision reports no column or table structure,
  and guessing at one would risk shuffling text on any layout more complex than
  a plain page or screenshot — worse than leaving it flat. Do not add
  multi-column detection without a real layout signal to drive it.
  Newspaper-style multi-column pages and forms with side-by-side fields are a
  known, accepted gap, not a bug to "fix" with a heuristic.
- **Line breaks are kept, not reflowed.** A wrapped line stays its own text
  line inside a paragraph rather than being rejoined into flowing prose — a
  screenshot or receipt has unrelated short lines next to each other that
  prose-reflow would incorrectly merge. This is why the canonical text uses
  `\n` between lines and `\n\n` between paragraphs, and both Markdown and RTF
  conversion work off exactly that convention.
- **The heading/separator convention lives in the merged text itself, not in a
  save-time transform.** A batch of more than one file gets each file's name as
  a heading and a `---` line between sections, built once into the text the
  user sees and edits; Copy and all three Save actions just use that text
  as-is. A single file or a pasted image gets no heading at all — same rule,
  driven only by how many results were produced.
- **RTF encodes real paragraphs as `\n`, wrapped lines as U+2028.**
  `TextRecognizer.makeRTF` turns each blank-line-separated paragraph into an
  RTF paragraph (with `paragraphSpacing`) and each line break inside it into a
  Unicode line separator, not a new paragraph — so paragraph spacing shows
  between paragraphs but not between a paragraph's own wrapped lines. Verified
  by round-tripping the generated RTF back into `NSAttributedString` and
  checking which breaks landed as `\n` versus U+2028.
- **Markdown only normalizes bullet markers to `-`.** No other Markdown
  interpretation is attempted; the canonical text (Copy, TXT, RTF) keeps
  whatever character Vision actually recognized.

### Merge Texts reads by content, never trusts the extension

`TextMerger.readText` sniffs a file's first bytes for the RTF signature
(`{\rtf1`) rather than checking its extension, and only falls back to
`String(contentsOf:usedEncoding:)` when that signature is absent. RTF is not
plain text — reading its bytes directly would put raw control words like
`{\rtf1\ansi…}` into the merged output instead of the document's actual
content — and a renamed or extensionless RTF file still needs to go through
`NSAttributedString` to come out clean. This mirrors the read side of what
`ImageMetadata`/embedded-metadata reading already does: never assume a file is
what its extension claims.

A file the picker or a drop happens to let through but that cannot actually be
read as text (a real binary, or bytes invalid in every encoding Foundation
tries) is skipped and reported by name, never fatal to the rest of the batch —
this is deliberate, not a gap: with `permitsAnyFile` (see below), the picker
and drop target accept anything, and the read attempt itself is the only real
gate.

`FileListEditor` gained one additive, default-`false` parameter,
`permitsAnyFile`, used only by Merge Texts: the file dialog's
`allowedContentTypes` cannot be overridden from outside the component the way
drag-and-drop can (that is attached externally via `.onDrop`), so this needed
an actual change to the shared file. Existing callers (Combine Images, Combine
Videos, Read Image Text) are unaffected since they never pass it.

### Convert Encoding's common-encoding list is verified, not assumed

`EncodingCatalog` builds its full encoding list from
`CFStringGetListOfAvailableEncodings` / `CFStringGetNameOfEncoding` — the same
source TextEdit's own "Reopen With Encoding" menu draws from — because
`String.Encoding` only names a handful of encodings directly; CP850,
ISO-8859-15, GB2312 and KOI8-R have no Swift constant and only exist by going
through `CFStringEncoding`. Three non-obvious things came out of actually
testing this against real encoded text, not just compiling it:

- **`CFStringEncodingExt.h`'s constants only reach Swift as cases of the
  `CFStringEncodings` enum** (e.g. `CFStringEncodings.dosLatin1`,
  `CFStringEncodings.GB_2312_80`), never as the flat `kCFStringEncoding…` C
  names one would expect from the header. There is no documented source for
  the exact Swift spelling; it was found by trial compilation.
- **GB2312's "obvious" constant doesn't work.**
  `CFStringEncodings.GB_2312_80` converts to a valid-looking
  `NSStringEncoding`, but Foundation's runtime then rejects it with "Unknown
  encoding" the moment it is actually used to encode or decode — confirmed
  directly, not assumed from the successful conversion. `CFStringEncodings.EUC_CN`
  carries the identical CoreFoundation name ("Simplified Chinese (GB 2312)")
  and does work; EUC-CN is the byte-level scheme that implements the GB 2312-80
  character set, which is what "GB2312" means in practice. Use `EUC_CN`, not
  `GB_2312_80`.
- **`String.Encoding.shiftJIS` is not plain Shift-JIS.** Swift's own named
  constant resolves to CoreFoundation's "Japanese (Windows, DOS)" — i.e. CP932
  — under the hood. The catalog deliberately uses
  `CFStringEncodings.shiftJIS` ("Japanese (Shift JIS)") instead, since that is
  the more literal match for what a user means by "Shift-JIS".

All nine common encodings were round-tripped with real text in their target
script (German, Japanese, Simplified Chinese, Russian, …) before being
considered correct — do not re-derive this list from documentation or
first-principles reasoning about the constant names; verify against real text
again if it ever changes.

Loss detection (`EncodingConverter.unrepresentableCharacterCount`) counts per
`Character` (grapheme cluster), not per Unicode scalar, so one emoji counts as
one — matching what a user perceives as "one character" — and
`allowLossyConversion: false` is what actually detects the loss; there is no
lossy-save escape hatch, by design, because a `?`-substituted write is exactly
the outcome the feature exists to prevent.

### Audio: what ffmpeg can actually do differs by container

Tag Editor and Track Splitter both work through `ffmpeg -c copy`, never
re-encoding. What each container format actually supports was tested directly
against real files in every accepted format — MP3, FLAC, M4A, raw AAC, OGG,
Opus, WAV — not assumed from format documentation, because several of the
results are not what the documentation would suggest:

- **`AudioFormatCapabilities.forExtension`** (`AudioTagEditor.swift`) is the
  single source of truth for what a format can do, and it looks like this
  because testing showed:
  - MP3, FLAC, M4A: every tag field and full cover art.
  - OGG, Opus: every tag field, but **no cover art**. The standard mechanism
    (a `METADATA_BLOCK_PICTURE` Vorbis comment, base64-encoded) can be written
    — it shows up in ffmpeg's own write-command log — but ffmpeg's muxer
    silently drops it before the file is finalized: reading the same file back
    immediately afterward shows no such tag at all. There is no reliable way
    to embed a cover into these two through ffmpeg. Do not re-attempt this
    without a real round-trip test proving otherwise.
  - WAV: every field except **Album Artist**, which is silently dropped on
    write (RIFF INFO chunks predate the concept of a separate album artist, so
    there is nowhere for ffmpeg to put it). No cover art — the wav muxer
    refuses any video stream outright ("wav muxer does not support any stream
    of type video"), not merely omitting it.
  - Raw AAC (`.aac`, ADTS): no metadata of any kind, tags or cover. ADTS has no
    tag container at all. The whole fields section is disabled with a note
    rather than silently no-opping.
- **Reading tags means parsing the `-i` banner, not `-f ffmetadata -`.**
  `-f ffmetadata -` only surfaces *container*-level metadata. MP3/FLAC/M4A/WAV
  keep their tags there, but Ogg/Opus keep theirs on the *audio stream*
  instead — invisible to `-f ffmetadata -`, which comes back with only
  ffmpeg's own `encoder` line: a result that looks like "no tags" and is
  actually just the wrong read path. `AudioTagEditor.readTags` parses the `-i`
  banner directly instead (the same source `VideoConcatenator.layout` already
  reads for stream info), collecting every `key : value` line under *any*
  `Metadata:` heading — container or per-stream — by tracking each heading's
  indentation and gathering deeper-indented lines until the indentation returns
  to that level or shallower.
- **ffmpeg refuses to edit a file in place.** Pointing its own output at its
  input exits immediately with "FFmpeg cannot edit existing files in-place" —
  confirmed directly; it does not fall back to any internal temp-file dance.
  `AudioTagEditor.write` builds that safety itself: ffmpeg's result goes to a
  hidden temp file next to the original, and only `FileManager.replaceItemAt`
  — called only after ffmpeg has actually exited 0 — swaps it in. A failure at
  any point leaves the original byte-for-byte untouched, verified with a
  deliberately-failing write.
- **Track Splitter's two-second edge buffer** (`AudioSplitter.edgeBuffer`) is a
  fixed constant, not a setting: silence starting in the first two seconds or
  ending in the last two seconds of the file is dropped before it ever becomes
  a cut point, on the assumption that an album-side or cassette rip almost
  always has some leading/trailing dead air that should not become its own
  track. Every other detected silence is treated as a real cut with no further
  heuristics — no attempt to trim silence *within* a track, and no attempt to
  detect a multi-second gap as "probably two silences."
- **`-ss`/`-to` before `-c copy` cuts on the nearest frame, not the exact
  sample**, for compressed formats — verified against a real MP3 cut to be
  within tens of milliseconds, not audibly broken. This is normal and not a
  bug to chase.

### Convert Format: one `ImageFormat` for both source and target

Batch mode reuses `ImageFormat` — the same type Convert Format's single-file
mode has always used as its target format — rather than introducing a second,
parallel format type for "what can be read." HEIC and HEIF are real cases on
it (`isReadOnly: Bool`), but no target picker anywhere may ever iterate
`ImageFormat.allCases` directly: that would silently offer HEIC/HEIF as
conversion targets, which ImageIO cannot write and which the design
deliberately never explains why not, it just never lists them. Both the
single-file target menu and the batch target menu iterate
`ImageFormat.writableCases` instead. If a new read-only format is ever added,
mark it `isReadOnly` and nothing else needs to change — every target picker
already filters through this one property.

`FolderRow` moved from being private to `CombineImagesView.swift` into
`Shared/FolderRow.swift` once Convert Format's batch mode became a second real
consumer needing the identical "path + detail text + Choose…" row — the same
promotion `FileRow` went through earlier for the same reason. Combine Images'
own behavior is unchanged; only where the view type lives moved.

Batch conversion has no process to terminate on Cancel — unlike the ffmpeg-
backed batch sections (Track Splitter, Combine Videos), each file goes through
plain ImageIO (`CGImageDestinationFinalize`), which is synchronous, in-process
and atomic per file: it either finishes or never started, with no partial
state a kill signal could catch mid-write. Cancel therefore works the same way
Read Image Text's batch does — `Task.isCancelled` checked before each file,
the current file (if any) finishes, the loop then stops — and this is not a
weaker guarantee than the process-terminating sections, just a different
mechanism arriving at the same "nothing half-written" outcome. Verified
directly: cancelling after a fixed number of files in a real batch leaves
exactly that many complete, valid output files and touches no others.

A per-file failure during a batch (corrupt or unreadable image) is skipped and
named in the final summary rather than aborting the batch — the same
skip-and-report convention Read Image Text and Merge Texts already use for
their own batches. Keep new batch features consistent with this rather than
reintroducing a stop-on-first-error variant.

### Quick Edit: Core Graphics coordinate gotchas and metadata capture

`ImageEditor.swift` does rotation and cropping with plain Core Graphics, no
external tool. Two coordinate-system traps here are easy to get backwards
without testing against a real, asymmetrically marked image — both were
actually wrong once during development and caught by exactly that kind of
test, not by re-reading the math:

- **Rotation sign.** SwiftUI's `.rotationEffect` is clockwise-positive (its Y
  axis increases downward); `CGContext.rotate(by:)` is counterclockwise-
  positive (a `CGImage`'s pixel buffer has Y increasing upward). `rotate(_:
  degrees:)` negates the angle before calling `CGContext.rotate(by:)` so the
  rendered pixels turn the same visual direction the on-screen preview implies.
  Verified against an independent PIL reference (`rotate(-30, expand=True)`),
  not assumed from the two conventions alone.
- **Crop has no flip.** `CGImage.cropping(to:)` indexes the pixel buffer
  directly — top-left origin, row-major — which is already the same
  convention the crop UI and its X/Y fields use. An earlier version flipped Y
  to "correct" for `CGContext` drawing's bottom-left origin; that convention
  does not apply here, and the flip was silently cropping the wrong half.
  Removing it was the fix. Do not reintroduce a flip in `crop(_:to:)` without
  re-testing against a marked image.

Pipeline order is rotate → crop → format-convert → strip metadata. Rotating
first is what lets the crop frame stay axis-aligned while still describing the
true post-rotation result; cropping first would mean the frame has to rotate
with the image, which the UI never does. Rotation fills newly-exposed corners
white *before* the crop frame is applied, so a frame placed over that border
is visibly white on the canvas, matching what gets saved.

**`CGImage` carries no EXIF/GPS metadata — ever.** Metadata lives only on the
`CGImageSource` the image was decoded from, and `CGImageDestinationAddImage`
writes none unless a properties dictionary is passed explicitly. This was
found as a real bug during end-to-end testing: `MetadataWriter.removeGPS` on a
Quick-Edit-written file reported `nothingToDo` because the file already had
*zero* metadata of any kind, not because GPS alone was already absent.
`ImageConverter.metadata(from:)` captures the source's properties via
`CGImageSourceCopyPropertiesAtIndex` at load time; `QuickEditView` holds them
in `sourceMetadata` and passes them into `ImageConverter.write(...)`'s
`metadata:` parameter at save time, which merges them into the destination's
options dictionary. The parameter defaults to `nil` everywhere else —
**Convert Format does not pass it and its output still carries no metadata at
all**, unchanged from before this existed; see the README's Known limitations
for that gap, which this session found but deliberately left unfixed as
out of scope.

Quick Edit's crop-handle drag is a `CGRect`-producing pure function
(`CropCanvas.applyHandleDrag`), not gesture-local state: each handle owns only
the edge(s) it moves, and the edges it does not own are never reassigned from
the drag delta, only clamped against the ones being moved. A more obvious
"adjust origin and size independently, then clamp size to the minimum"
approach lets the fixed/anchor edge drift once the drag overshoots past the
opposite edge or the canvas bounds — verified with a standalone test covering
normal drag, single-edge overshoot, diagonal overshoot past the opposite
corner, and overshoot past canvas bounds, before this ever shipped.

The crop rect resets to the full (post-rotation) canvas whenever
`quarterTurns` or `fineAngle` changes, rather than trying to carry a crop
selection across a rotation. A rect meaningful in the old rotated coordinate
space has no clean mapping to the new one without either the user's own
intent (which MIKE cannot know) or GPU-provided undo, and always-reset is a
consistent, boring, correctly-documented behavior over a partially-correct
carry-forward heuristic.

`ExifToolWrite.run` and `MetadataWriter.removeAll`/`removeGPS` take an
opt-in `skipBackup: Bool = false`, used only by Quick Edit. exiftool's usual
`_original` backup exists to protect a real source file the user did not
intend to lose; Quick Edit's metadata step runs on the file it just wrote
itself a moment earlier at the user's chosen save path — the actual, untouched
original lives elsewhere and was never opened for writing — so a `_original`
sidecar next to the save target would only be clutter. Every other caller
(Metadata, Embedded) still defaults to `skipBackup: false` and keeps the
existing backup behavior unchanged.

### The app is localized

All user-visible text lives in `MIKE/Localizable.xcstrings`. **English is the
source language**; translations exist for **German and Spanish**. Every change
to visible text has to be carried through all three languages.

Not translated, and marked `shouldTranslate: false` in the catalog where they
appear as keys: proper names (MIKE, yt-dlp, ffmpeg, cwebp, exiftool, ssstik),
format names (JPEG, WEBP, PNG, HEIC, HEIF, TIFF, BMP, GIF, MP3, FLAC, M4A, AAC, OGG, OPUS,
WAV), metadata standard names (EXIF,
GPS, TIFF, IPTC, XMP) and the tag names exiftool/ImageIO report, PNG chunk names
(`tEXt`, `zTXt`, `iTXt`, `eXIf`) and embedded key names such as `parameters`,
`prompt` and `workflow`, encoding names (UTF-8, Windows-1252, Shift-JIS and the
rest of `EncodingCatalog`'s names, exactly as CoreFoundation names them),
Homebrew commands, output file names such as `combined.jpg` and the
`_original` suffix, URL placeholders, and anything printed by the external
tools or the system — that output is English and stays English. The metadata
tag names and values in the Metadata and Embedded lists, and the encoding
names in Convert Encoding's pickers, are rendered with `Text(verbatim:)` so
they never become catalog keys.

Writing new text:

- SwiftUI only localizes **string literals**. A `String` arriving through a
  variable is shown verbatim, so anything assembled at runtime needs
  `String(localized:)`, and view properties that carry text need to be typed
  `LocalizedStringKey`, not `String`.
- Wrap file names, paths and numbers in `Text(verbatim:)` so they never become
  catalog keys.
- Do not build a sentence by interpolating a translated noun — other languages
  inflect the rest of the sentence. Pass whole sentences instead, the way
  `FileListEditor` takes `emptyMessage` and `addTitle`.
- Counts use explicit plural variations in the catalog, not
  `inflect: true` — the automatic grammar engine does not cover German well.

`SWIFT_EMIT_LOC_STRINGS` is on, so the compiler extracts every key into
`.stringsdata` during a build. That is the reliable way to find what is
actually localizable — grepping misses strings that flow through variables.

**At the end of every task, check the catalog for entries left untranslated in
German or Spanish and report them.**

Keep the sidebar labels short: that column is the narrowest place in the UI and
must not wrap or truncate.

### README

`README.md` embeds `images/MIKE_Icon.png` and `images/MIKE_Screenshot.png`.
**Preserve those embeds unchanged** when editing the file, and keep new images
in `images/`.

## Open items

- **No standing-rules sections yet for the five Files-category tools**: Hash
  Check, Batch Rename, File Info, Find Duplicates, and Compression. Every
  other non-trivial section in this file earned its own subsection under
  "Standing rules" documenting the non-obvious decisions and gotchas found
  while building and verifying it (the `_original` backup rule, the
  Convert Encoding constant-name traps, the audio container capability
  matrix, and so on). These five tools almost certainly have comparable
  decisions buried in their code — e.g. Compression's password-protection
  detection workaround, its pinned SWCompression/BitByteData versions for
  macOS 13 compatibility, or Batch Rename's conflict-detection rule — but
  writing that up from a fresh read of the code would be guessing at which
  details were actually load-bearing versus incidental. Deliberately left
  unwritten here rather than filled in from assumption; add real subsections
  once each tool's non-obvious behavior has been verified the way the
  existing sections were, not reconstructed from reading the source once.
- **Trim Video's crop addition is undocumented too**: the section above only
  describes Trim Video's original cut-without-re-encoding behavior. The
  optional crop (re-encodes to H.264/AAC, relies on ffmpeg's own autorotate
  rather than hand-computing rotation) was added after that section was
  written and never folded back into it — noticed while fixing the utility
  count above, not chased down further; same "write it up once verified,
  don't guess" rule applies.
