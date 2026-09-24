# Happy Drive

A private, Google Photos–style photo library for you and a few friends. Photos back up to **your own private Hugging Face Storage Bucket**, and they're **encrypted on the phone before they leave it**, so Hugging Face (or anyone else) sees only scrambled data.

Flutter app for Android and iOS. There's no server: the app talks straight to your bucket.

## Try it on a phone

[**Download the Android test build (.apk)**](https://github.com/Reubencfernandes/happy-face/releases/latest/download/happy-drive.apk)

A universal release APK signed with Flutter's standard debug key, so it installs
without a Play Store account — Android will warn about an unknown source, which
is expected for a test build. You'll need a Hugging Face account and S3
credentials first: see [Setting up](#setting-up-each-person-once). There's no
iOS build yet; that needs macOS and Xcode.

## What it does

- **Timeline:**
  - Newest photos first, grouped by day, or by month when zoomed out.
  - Pinch to change density; drag the scrubber to jump by date.
  - Sort by date taken or date uploaded, and filter by backup state.
  - Photos on the phone and in the cloud appear together, with a badge showing which are backed up.
- **Files:** PDFs and audio have a tab of their own, listed by name, size and
  date, with an Upload button that picks just that kind of file.
- **Calendar:** every month as a grid of days, each day wearing one of its
  photos; empty days stay empty, so the gaps show.
- **Backup:**
  - Photos, videos and any other file — pick them in the grid, import them from
    Files, or back up everything not yet backed up.
  - Upload quality chosen per backup, down to a single photo: Original
    (default), High or Balanced. Audio is re-encoded to AAC and the photos
    inside PDFs are shrunk, text untouched; videos and other files are stored
    as they are.
  - Identical photos are stored once, even across phones.
  - Interrupted uploads resume.
  - **Live status:** a bar under the title says how far along the backup is,
    how fast and how long is left, and whether it is still getting photos
    ready. Tapping it opens the whole picture: every file in flight with its
    own progress, a running list of what finished, and anything that failed
    with the reason. The count moves as each file's bytes land, not in jumps
    of ten when the catalogue is written, and a large video moves the bar as
    it uploads rather than pausing it.
  - **Stop means stop.** It finishes the files already uploading, starts
    nothing new, and says "Stopping" while it winds down. Photos it never got
    to are left for next time rather than reported as failures.
- **Auto-backup:**
  - Runs whenever the app opens.
  - On Android it also runs as a periodic background task (Wi-Fi only by
    default). That task stands aside while the app itself is backing up, so
    there is only ever one backup running and Stop can always reach it.
- **Viewing:** photos zoom, videos and sound files play in the app, and short
  text files show their contents. Anything else is named, sized and offered as
  a download. Whatever is on the phone is read from the phone — that copy is
  the untouched original, and the backup may have been compressed — and the
  viewer says which of the two you are looking at.
- **Places:** photos grouped by town and country, using a built-in offline list (GeoNames). Your coordinates never leave the phone.
- **Weather (opt-in):** past weather for each photo from Open-Meteo, using only a rounded location (about 11 km) and the date.
- **Search:** places, weather, file names and dates ("Lisbon 2025", "rain", "December").

## Setting up (each person, once)

1. **Sign in** to [huggingface.co](https://huggingface.co). A free account includes 100 GB of private storage; PRO includes 1 TB.
2. **Create a Write token** at **Settings → Access Tokens**.
3. **Generate S3 credentials:** in the token list, open the token's menu (⋯) and choose **Generate S3 credentials**. Copy the access key (`HFAK…`) and the secret; the secret is shown only once.
4. **Make the bucket, and make it private.** Hugging Face buckets are **public unless you say otherwise**, and the S3 gateway the app talks to has no way to set that. So create it yourself at [huggingface.co/new-bucket](https://huggingface.co/new-bucket) and choose **Private**.
   - If you skip this, the app creates the bucket for you and it will be public. The app checks, refuses to use it, and tells you to switch it to private in the bucket's settings.
   - Photos are encrypted either way, but a public bucket lets anyone list and download the encrypted files.
5. **Connect:** in the app, enter your username, the access key and the secret, then say where the photos go:
   - **New bucket** makes one, under a name the app suggests. It refuses a bucket that already holds a library, so a second phone can't start a second one by accident.
   - **My bucket** opens a library that's already there — type the name, or tap **Browse my buckets** to see the ones in the account, with the ones holding a Happy Drive library marked. (Hugging Face doesn't always answer a listing request; when it doesn't, the app says so and you type the name.)
   - A phone that has connected before starts on **My bucket**, already filled in.
6. **Choose a passphrase.**
   - It encrypts everything. **There is no recovery: forget it and the photos can't be opened.**
   - A new phone needs the same three sign-in values plus the passphrase.
   - On Android, **Save to Google Password Manager** keeps it there, and **Use saved passphrase** fills it in on a new phone.

Buckets you no longer want can be deleted from **Settings → Manage buckets**, except the one the phone backs up to.

Files of any size back up: anything over 64 MB goes up in encrypted 8 MB pieces, read off the disk one at a time. Delete asks whether to remove the backup, the phone's copy, or both. PDFs and audio open in the app, and **Settings → Phone storage** shows how much room the phone and Happy Drive are using.

**Reinstalling:** if you reinstall the app, choose **My bucket** (or accept the offer to open your existing library) and enter the same passphrase. Your photos are in your bucket, not on the phone.

## Running

```
flutter pub get
flutter test
flutter run
```

- **iOS** builds need macOS and Xcode; set your signing team in Xcode.
- **Android:** debug builds work from Windows. Kotlin incremental compilation is turned off in `android/gradle.properties` because the project and the Pub cache are on different drives.

## How it works

### Why a bucket

Storage Buckets are Hugging Face's non-git, S3-style object storage:
- Deleting a photo really frees space; a dataset repo keeps every version forever.
- There are no commit or per-folder limits.

The app uses the bucket's S3-compatible gateway at `https://s3.hf.co/<username>`, signing requests itself (`lib/s3/`). "S3" here is only the name of the storage protocol. Everything stays in your own Hugging Face account.

### What's in the bucket

Every object name is meaningless to anyone without your key:

```
v1/keys              your master key, locked with your passphrase (Argon2id)
v1/index/<n>         encrypted catalogue snapshot
v1/j/<time>-<rand>   encrypted catalogue changes since the snapshot
v1/o/<ab>/<id>       encrypted original
v1/t/<ab>/<id>       encrypted thumbnail
```

- **Encryption:** AES-256-GCM (`lib/crypto/vault.dart`). Each file is bound to its object name, so encrypted files can't be swapped for one another.
- **Where the work happens:** the platform's own crypto handles files up to the size its API will take — 20 MB on Android, 100 MB on iOS. Above that the library falls back to Dart, which would otherwise run on the isolate that draws the gallery and freeze it, so big files are encrypted and fingerprinted on a worker isolate instead.
- **Playing a video** is the one exception to "nothing readable is ever written down". The platform player needs a file, so a video from the bucket is decrypted into the OS cache folder while it plays, deleted the moment the viewer closes, and swept at sign-in in case the app died with one open (`lib/media/media_file.dart`). A video already on the phone is played from the phone's own copy and nothing is written at all.
- **Photo ids:** a secret-keyed fingerprint of the original bytes. This is how duplicates are detected without Hugging Face being able to tell two files match.
- **What Hugging Face can see:** file sizes, file counts and upload times. Not photos, names, dates or places.
- **Nothing leaves the phone unencrypted.** No photo or thumbnail is ever sent to a third-party service.

### Keeping phones in sync

Every change is a small encrypted journal entry (`lib/data/remote_catalogue.dart`).
- About every 200 changes, a phone folds the journal into numbered snapshots, created with `If-None-Match: *`.
- If two phones compact at once, one write is refused and that phone reloads. Nothing is lost.
- A local SQLite database (`lib/data/local_db.dart`) mirrors the catalogue for an instant, offline timeline and full-text search.

### Code map

| Path | What |
|---|---|
| `lib/s3/` | SigV4 signing (checked against AWS test vectors) and the bucket client |
| `lib/crypto/vault.dart` | Passphrase, master key, encryption, photo ids |
| `lib/data/` | Catalogue, sync with the bucket, local database |
| `lib/sync/` | Upload pipeline, thumbnail cache, background backup |
| `lib/media/` | Phone gallery, EXIF, compression, file types, playable copies |
| `lib/enrich/` | Offline places, weather |
| `lib/app/` | Session (ties it all together), stored credentials, settings |
| `lib/ui/` | Screens |

## Testing

`flutter test` runs about 160 tests, all against an in-memory fake bucket. No test touches a real account. They cover:
- SigV4 signing against official AWS vectors
- encryption, tampering and wrong passphrases
- two phones syncing and compacting at the same time
- deduplication, retries, resuming and stopping early on bad keys
- EXIF dates, time zones and GPS, using camera-format test JPEGs
- the timeline, search and places
- weather error handling
- refusing a file too large to hold, without opening it
- noticing a bucket deleted on the website, without mistaking a dropped
  connection or one missing object for it
- the first-run flow on a phone-sized screen, both ways into a bucket
- upload and download progress, and the live backup status
- stopping a backup: that it stops promptly, invents no failures, and isn't
  forgotten if it lands while photos are being got ready
- that the library isn't re-queried on every progress tick
- decrypting a video to a playable file, and cleaning it up again
- that a photo edited since its backup stops claiming to be backed up

### Live checks (opt-in)

`test/live/` holds checks that talk to real services. They're skipped by default, so `flutter test` stays offline.

```bash
# Weather
LIVE_WEATHER=1 flutter test test/live/weather_test.dart

# Storage, end to end: creates a throwaway bucket in your account
HF_NAMESPACE=your-username HFAK_KEY=HFAK... HFAK_SECRET=... flutter test test/live/storage_test.dart
```

The storage check creates the bucket, stores the library key, backs up photos (including a duplicate), confirms the bucket holds only unreadable data, downloads and decrypts, loads the library as a second device, compacts the journal and deletes. It leaves the test bucket behind for you to look at, and prints its address.

### Checking against a real account

1. Connect and set a passphrase. The `happy-drive` bucket shows up as private in your account.
2. Back up about 20 photos, including one duplicate. Expect 19 stored.
3. Open the bucket on huggingface.co. File names should be random and previews unreadable.
4. Force-quit during a backup, reopen, and confirm it resumes with no duplicates.
5. Delete a photo and check the bucket size drops.
6. Reinstall, sign in with the passphrase, and confirm the library comes back.

## Current limits

- **Real-world testing:** run on a physical Android phone (Oppo CPH1933, Android 11) against a real Hugging Face account — sign-in, bucket browsing, backup, stopping a backup and the oversized-file refusal are all confirmed there. The iOS build of the current changes has not been run on a device. Verified so far: weather against the live service, and the whole storage stack (sign-in, encrypted upload, download, dedupe, sync, compaction, delete) against a real S3 server locally, plus a real backup to a real Hugging Face bucket from the phone. Request signing matches botocore byte-for-byte for the app's own request shapes. What's still unproven is the Hugging Face gateway itself: run the live storage check to confirm it.
- **iPhone background backup:** it happens when the app opens; the iOS background task isn't set up yet.
- **Videos and files:** videos and sound play in the app, and short text files
  show their contents; a PDF or a zip is still only named, sized and offered as
  a download. A video imported from Files has no thumbnail in the grid, because
  making one needs a package that isn't compatible with this Dart version —
  videos from the phone's own library do have one. The motion half of a Live
  Photo isn't uploaded either; the still is.
- **One file at a time, up to 64 MB:** each upload is a single request, so the
  whole file sits in memory — twice over while it is encrypted, and once more
  on the Android heap as it crosses from the photo library. A mid-range phone
  caps that heap near 384 MB, so a 215 MB video doesn't merely fail, it kills
  the app. The size is now read from the file system before a byte is loaded,
  anything larger is refused with a clear reason, and large files go up one at
  a time. Chunked uploads would lift the limit; until then, long videos can't
  be backed up from a phone.
- **Not supported yet:** albums, sharing, face grouping, map view, Windows and web.
- **Deleting photos:** removes the files right away. If a delete fails partway, the leftover files are hidden from the library but still use storage until cleaned up.
- **A bucket deleted on huggingface.co** is noticed on the next sync: the app says so plainly and offers to connect to another one, rather than carrying on showing photos from its local mirror that no longer exist anywhere.
- **App Store export compliance:** the app uses its own encryption, so answer Apple's question accordingly when submitting.

## Releases

[`CHANGELOG.md`](CHANGELOG.md) records what changed in each build and why.

## Credits

- Place names: [GeoNames](https://www.geonames.org), CC BY 4.0.
- Weather data: [Open-Meteo.com](https://open-meteo.com), CC BY 4.0. Its free API is for non-commercial use.
