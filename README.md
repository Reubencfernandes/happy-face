# HF Drive — Flutter

Native Flutter photo app for Android, iOS, and Windows. The app talks directly to Hugging Face; no Node server or web backend is needed.

## Start

```
cd E:\hf-drive
flutter pub get
flutter run
```

Choose an Android device/emulator or Windows. iOS builds require macOS and Xcode.

Create a dataset at https://huggingface.co/new-dataset and select **Private**. Generate a Hugging Face token with read and write access to that dataset at https://huggingface.co/settings/tokens. Enter the dataset name (`username/my-photos`) and token in the app. Never put tokens in source code or chat.

## Included

- Secure device storage for the token; disconnect clears saved credentials.
- Private dataset validation, paginated file listing, filename search.
- Native file selection with sequential multi-photo upload and per-file results.
- JPEG, PNG, GIF, WebP; 25 MB per file. Uploaded content is checked by signature.
- Original photos under `photos/YYYY-MM-DD/random-id--filename.ext`.
- Regular Git and basic LFS upload negotiation, followed by a dataset commit.
- Photo grid, zoomable preview, and save-original action.
- Explicit download redirects prevent forwarding the HF token to signed storage URLs.

## Validation

Run `flutter analyze` and `flutter test`. Service tests mock HTTP; they never upload to a real account. A real end-to-end Hugging Face check needs your credentials.

## Current limits

This is an initial single-user app. No background sync, albums, deletion, resumable uploads, or HEIC conversion. Previews download originals and resize them for display; optimized remote thumbnails are not implemented. Uploads run while the app stays open. Listings follow pagination but are retained in memory. Hugging Face account quotas and service terms apply. Dataset history can retain previous versions; keep an independent backup of important photos.

Android includes Internet permission and disables Android backup for stored credentials. Native system file pickers avoid requiring broad storage permissions. The iOS scaffold is included but must be built and tested on a Mac. Secure storage on iOS uses Keychain; configure the signing team in Xcode for your device.

Service implementation: `lib/hf_service.dart`. Flutter screens: `lib/main.dart`.

Protocol reference: https://huggingface.co/docs/hub/api

Android note: Kotlin incremental compilation is disabled in this project to avoid cache errors when the project is on E: and the Pub cache is on C:. Windows desktop builds require Visual Studio's Desktop development with C++ workload.

Validation on this PC: flutter analyze passed with no issues; all seven Flutter tests passed; flutter build apk --debug succeeded. The APK is at build/app/outputs/flutter-apk/app-debug.apk. No physical-device session or real Hugging Face transfer was performed. iOS and Windows binaries were not built.
