# Changelog

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
