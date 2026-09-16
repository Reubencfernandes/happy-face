# Happy Drive

A private, Google Photos–style photo library for you and a few friends. Photos back up to **your own private Hugging Face Storage Bucket**, and they're **encrypted on the phone before they leave it**, so Hugging Face (or anyone else) sees only scrambled data.

Flutter app for Android and iOS. There's no server: the app talks straight to your bucket.

## What it does

- **Timeline:**
  - Newest photos first, grouped by day, or by month when zoomed out.
  - Pinch to change density; drag the scrubber to jump by date.
  - Sort by date taken or date uploaded, and filter by backup state.
  - Photos on the phone and in the cloud appear together, with a badge showing which are backed up.
- **Backup:**
  - Pick photos, import files, or back up everything not yet backed up.
  - Upload quality per upload: Original (default), High or Balanced.
  - Identical photos are stored once, even across phones.
  - Interrupted uploads resume.
- **Auto-backup:**
  - Runs whenever the app opens.
  - On Android it also runs as a periodic background task (Wi-Fi only by default).
- **Places:** photos grouped by town and country, using a built-in offline list (GeoNames). Your coordinates never leave the phone.
- **Weather (opt-in):** past weather for each photo from Open-Meteo, using only a rounded location (about 11 km) and the date.
- **AI descriptions (opt-in):**
  - Captions and tags from a vision model on Hugging Face Inference Providers (default `Qwen/Qwen3.8-27B`), searchable offline.
  - Only the small thumbnail is sent.
  - A daily limit applies, and describing pauses automatically when credits run out.
- **Search:** captions, tags, places, weather, file names and dates ("beach 2025", "rain", "Lisbon").

## Setting up (each person, once)

1. **Sign in** to [huggingface.co](https://huggingface.co). A free account includes 100 GB of private storage.
2. **Create a Write token** at **Settings → Access Tokens**.
3. **Generate S3 credentials:** in the token list, open the token's menu (⋯) and choose **Generate S3 credentials**. Copy the access key (`HFAK…`) and the secret; the secret is shown only once.
4. **Connect:** in the app, enter your username, the access key and the secret.
   - The app creates a private bucket called `happy-drive`.
   - If a bucket with that name is public, it refuses to use it.
5. **Choose a passphrase.**
   - It encrypts everything. **There is no recovery: forget it and the photos can't be opened.**
   - A new phone needs the same three sign-in values plus the passphrase.
6. **AI descriptions (optional):** add a token with the **Make calls to Inference Providers** permission in Settings.
   - Free accounts get about $0.10 of credits a month.

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
- **Photo ids:** a secret-keyed fingerprint of the original bytes. This is how duplicates are detected without Hugging Face being able to tell two files match.
- **What Hugging Face can see:** file sizes, file counts and upload times. Not photos, names, dates, places or captions.
- **The one exception:** with AI descriptions on, thumbnails are sent to the AI provider unencrypted. The app explains this before you turn it on.

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
| `lib/media/` | Phone gallery, EXIF, compression, file types |
| `lib/enrich/` | Offline places, weather, AI descriptions |
| `lib/app/` | Session (ties it all together), stored credentials, settings |
| `lib/ui/` | Screens |

## Testing

`flutter test` runs about 100 tests, all against an in-memory fake bucket. No test touches a real account. They cover:
- SigV4 signing against official AWS vectors
- encryption, tampering and wrong passphrases
- two phones syncing and compacting at the same time
- deduplication, retries, resuming and stopping early on bad keys
- EXIF dates, time zones and GPS, using camera-format test JPEGs
- the timeline, search and places
- weather and AI error handling
- the first-run flow on a phone-sized screen

### Live checks (opt-in)

`test/live/` holds checks that talk to real services. They're skipped by default, so `flutter test` stays offline.

```bash
# AI descriptions, against your account
HF_TOKEN=hf_... TEST_IMAGE=/path/to/photo.jpg flutter test test/live/caption_test.dart

# Weather
LIVE_WEATHER=1 flutter test test/live/weather_test.dart

# Storage, end to end: creates a throwaway bucket in your account
HF_NAMESPACE=your-username HFAK_KEY=HFAK... HFAK_SECRET=... flutter test test/live/storage_test.dart
```

The storage check creates the bucket, stores the library key, backs up photos (including a duplicate), confirms the bucket holds only unreadable data, downloads and decrypts, loads the library as a second device, compacts the journal and deletes. It leaves the test bucket behind for you to look at, and prints its address.

### Checking against a real account

1. Connect and set a passphrase. The `happy-drive` bucket appears in your account.
2. Back up about 20 photos, including one duplicate. Expect 19 stored.
3. Open the bucket on huggingface.co. File names should be random and previews unreadable.
4. Force-quit during a backup, reopen, and confirm it resumes with no duplicates.
5. Delete a photo and check the bucket size drops.
6. Reinstall, sign in with the passphrase, and confirm the library comes back.

## Current limits

- **Real-world testing:** nothing has been tested yet against a real Hugging Face account or on a physical phone, and no iOS build has been made.
- **iPhone background backup:** it happens when the app opens; the iOS background task isn't set up yet.
- **Not supported yet:** videos, albums, sharing, face grouping, map view, Windows and web.
- **Deleting photos:** removes the files right away. If a delete fails partway, the leftover files are hidden from the library but still use storage until cleaned up.
- **App Store export compliance:** the app uses its own encryption, so answer Apple's question accordingly when submitting.

## Credits

- Place names: [GeoNames](https://www.geonames.org), CC BY 4.0.
- Weather data: [Open-Meteo.com](https://open-meteo.com), CC BY 4.0. Its free API is for non-commercial use.
