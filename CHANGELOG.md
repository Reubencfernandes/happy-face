# Changelog

## 1.2.0 — 2026-09-24

### Fixed: an update could leave you in an empty library

The Android test build on GitHub was signed with a debug key from another
computer, so no later APK could install over it: Android made people uninstall
first, which wiped the phone's sign-in and library index. On the fresh install
the connect screen started on **New bucket**, and tapping through it made a
new, empty library. The photos were never lost (they stay in the old bucket),
but they were out of sight.

- Before making a new bucket, the app now looks for libraries already in the
  account and offers to open one. Starting an empty one is still possible, on
  purpose.
- The GitHub release now carries the APK signed with Happy Drive's own key,
  which every later build uses too.

### New: files of any size

Anything over 64 MB, whether a long video, a big PDF or a recording, now goes
up in 8 MB pieces, each encrypted on its own and bound to its place in the
file, so pieces can't be reordered or dropped unnoticed. The file is read off
the disk a piece at a time, so a 2 GB video needs no more memory than a photo.
A dropped connection resumes from the last piece rather than starting over.
Playing or saving it downloads and decrypts the pieces straight into a file.
Files up to 64 MB are stored exactly as before, so older copies of the app
can still open everything they could. The limit per file is now 16 GB.

### New: delete from Happy Drive, from the phone, or both

Delete, in the viewer or on a selection, asks where from: **Happy Drive**
(the phone keeps its copy), **this phone** (the backup stays, to free space),
or **everywhere**. It only offers what applies, and says when something would
be gone for good. If the phone's own confirmation is declined for some
photos, their backups are kept too.

### New: read PDFs and play audio in the app

PDFs open page by page, drawn by the phone's own PDF renderer (PdfRenderer on
Android, Core Graphics on iOS), with pinch to zoom. Audio gets a player of its
own: name, play and pause, a scrubber and the time.

### New: phone storage in Settings

Under **Manage buckets**, Settings shows how full the phone is, how much of
that is Happy Drive, and what Happy Drive keeps: its library index,
thumbnails and temporary files.

### Fixed

- Backing up a single photo from the viewer now shows it as backed up
  straight away, instead of only after leaving and reopening it.
- Saving a video from a selection saves it as a video, not as a photo.
- The delete sheet no longer overflows on short screens.

## 1.1.0 update — 2026-09-24 (TestFlight 202609241204)

### New: a Files tab for PDFs and audio

A fifth tab in the bar keeps PDFs and sound files, with a switch between the
two. They're listed by name, size and date rather than as a grid of icons, and
no longer crowd the photo gallery or the calendar. On this tab, **Upload**
opens a picker for just that kind of file. Audio is picked from Files, not the
music library, so voice memos and recordings show up on iPhone too.

### New: compression for PDFs and audio

The same Original / High / Balanced choice photos get, with wording for each
kind of file:

- **Audio** is re-encoded to AAC in an `.m4a` with the phone's own encoder
  (MediaCodec on Android, AVFoundation on iOS): up to 160 kbps at High, 96 kbps
  at Balanced, less for mono. A 30-second WAV went from 5.3 MB to 0.3–0.5 MB.
  Audio above 48 kHz is brought down to 48 kHz on iPhone; Android keeps such
  files as they are.
- **PDFs** have the photos inside them re-encoded; text, fonts and drawings are
  copied byte for byte. Balanced brings scanned pages to about 150 dpi. A PDF
  that is encrypted, damaged, or has only small pictures is stored untouched.

Either way, a file that wouldn't come out smaller is kept as it was.

### New: delete buckets you don't need

**Settings → Manage buckets** lists every bucket in the account with its size
and file count, and marks the ones that hold a Happy Drive library. Any of them
except the one this phone backs up to can be deleted: you type the bucket's
name to confirm, then its files go first and the bucket after, with a progress
bar. Keys made from a Read token are told they can't delete.

### New: save the passphrase to Google Password Manager (Android)

Creating a library offers **Save to Google Password Manager** once both entries
match, and unlocking offers **Use saved passphrase**. It's saved under the
library's `username/bucket`, so two libraries don't overwrite each other.
Libraries made before this can use **Settings → Save passphrase**, which checks
the passphrase against the library before keeping it. iPhone doesn't have this
yet: iOS only offers to save passwords for apps tied to a website.

### Android release signing

Release APKs are now signed with Happy Drive's own upload key (read from an
uncommitted `android/key.properties`), not the debug key. A copy installed from
an earlier debug-signed APK has to be uninstalled once before this one will
install over it.

### New look

- A new app icon: the cloud climbing out of its drive.
- The welcome screen's sunrise is now a single grainy arc, peach to orange to
  red, that rises from the bottom of the screen and keeps rippling gently.

## 1.1.0 — 2026-09-22

The first build tested on a real phone, which is how most of this was found.

### Fixed: backups killed the app

On a phone with large videos, a backup didn't stall — **the app was being
killed by Android and restarting**, over and over. Reading a file pulled the
whole thing into memory, and the size check ran *after* the read, so a 215 MB
video died before anything could decide it was too big:

```
java.lang.OutOfMemoryError: Failed to allocate a 221860224 byte allocation
Process com.happydrive.app (pid 17094) has died
```

The size is now asked of the file system before a byte is loaded, files that
won't fit are refused with a clear reason, and large files go up one at a time
so four of them are never in memory together.

**This is why backups looked stuck and why Stop appeared to do nothing —
there was frequently no process left to stop.**

### Fixed: the backup counter never moved

It read "Backing up 1 of 284" for the first ten photos, because a photo only
counted once its catalogue entry was written, and those go up in batches of
ten. It now counts a photo the moment its bytes reach the bucket, and the bar
includes the file in flight, so one large video moves it instead of pausing it.

No time estimate ever appeared either — it was gated on that same stuck
counter. It now shows within seconds and converges as it goes.

The progress callback was also re-running an unbounded library query inside
`setState` up to twelve times a second, in three live views at once. That
pegged the UI thread and dropped taps. It is throttled, and only the status
bar and backup button follow a running backup frame by frame.

### Fixed: Stop now stops

- The uploader cleared its own cancel flag at the start of every batch, so a
  Stop pressed while photos were being got ready was silently erased and a
  fresh batch of fifty began.
- Stopping marked every remaining photo as failed. Stopping a 2000-photo
  backup reported about 1900 failures. Photos it never reached are now simply
  left for next time.
- Tapping Stop changed nothing on screen. It now says "Stopping — finishing
  N files" with a spinner, and reports "Stopped · N backed up" at the end.
- An hourly background task ran its own backup in a separate isolate that the
  in-app Stop could not reach, with both writing the same database. It now
  stands aside while the app itself is backing up.

### New: watch a backup happen

A bar under the gallery title shows how far along it is, how fast, how long is
left, and whether it is still getting photos ready. Tapping it opens every
file in flight with its own progress, a running list of what finished, and
anything that failed with the reason.

### New: choose where the photos go

Sign-in now asks up front. **New bucket** makes one and refuses a name that
already holds a library; **My bucket** opens one that exists, with **Browse my
buckets** listing the account's buckets and marking which already hold a Happy
Drive library. A misspelt name is an error rather than a silently created
empty bucket.

### New: videos and sound play in the app

They used to be a card telling you to save the file to your phone first. Short
text files show their contents. Anything else is named, sized and offered as a
download.

Whatever is on the phone is read from the phone — that copy is the untouched
original, while the backup may have been compressed — and the viewer now says
which of the two you are looking at.

### Fixed: what is and isn't backed up

- The state badge was a 16px white cloud with no scrim, and all three states
  used near-identical glyphs. Each now sits on a dark chip, and the one that
  needs doing is the one with colour in it.
- Photos not backed up **vanished entirely** when sorting by upload date or
  browsing a place, so the one view that answers "what isn't safe yet" could
  come back empty.
- A photo edited since its backup still showed a "Backed up" badge while the
  app queued it for upload. The badge now agrees with the queue.
- Android 13+ was missing `READ_MEDIA_VIDEO`, so videos on the phone were not
  readable at all.

### Fixed: a bucket deleted on huggingface.co

Deleting the bucket on the website left the app showing every photo from its
local mirror with only a vague "not found". It now says so plainly and offers
to connect to another bucket — while telling that apart from one missing
object and from a dropped connection, so bad Wi-Fi never announces a deletion.

### Changed: the way in

- The sunrise on the welcome screen rises into place when the app opens, then
  keeps swelling gently. With Reduce Motion on it stays still.
- The guide to getting your keys is a card at the top of the connect page
  instead of small grey text under the form, where most people missed it. It
  takes the subtitle's place, so the form still fits a phone.

### Also

- A download that dies half way through is retried as a whole. Half a file is
  no use, and previously only the request was retried, not the body.
- Uploads and downloads report their bytes as they move.
- The keyboard on the sign-in and passphrase pages can be dismissed by tapping
  the page. Previously only the system Back button closed it.
- The backup button says **Upload**, rather than being a bare arrow.
- The sort-and-filter button is a filter mark, not an app grid.
- Measuring storage shows a skeleton in the shape of the numbers to come
  instead of a spinner, and respects reduced-motion settings.
- Encryption of large files, and the fingerprint used for deduplication, moved
  off the isolate that draws the gallery. Above 20 MB on Android (100 MB on
  iOS) the platform's crypto hands back to Dart, which ran inline and froze
  the UI.

### Known limits

- **Files over 64 MB are not backed up.** That is a memory limit, not a
  protocol one: each upload is a single request, so the whole file is held in
  memory, twice over while encrypting, and once more crossing from the photo
  library. Chunked uploads would lift it.
- Verified on a physical Android phone. The iOS build of these changes has not
  been run on a device.
- A video imported from Files still has no thumbnail in the grid.
- Search matches file names, places, weather and dates. It does not look at
  the contents of photos.

## 1.0.0 — 2026-09-21

First TestFlight build: encrypted backup to a private Hugging Face bucket,
timeline, calendar, places, weather and search.
