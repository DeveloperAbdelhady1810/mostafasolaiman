# Attendance Assistant

Cross-platform (Android + iOS) Flutter app for mostafa-solaiman.online's in-center attendance system. Built for the "assistant" role — center staff who take attendance for a teacher's courses, matching the existing `/api/assistant/*` API (originally built for a desktop app).

## Features

- Login with an assistant account (`role=assistant`, must have an active `assistant_profiles` row)
- Pick a center → filter by stage/grade → pick a course
- Roster screen: mark each expected student present/absent, tick homework done, enter a quiz mark (once a quiz scale is set via the toolbar icon)
- **Scan QR**: scans a student's dashboard QR code (`LQ-000123` format) and marks them present by matching against the loaded roster; falls back to a live server search if they're not on this course's expected list
- **Add Walk-in**: search any student on the platform by name/phone/email/student number and add them to the roster
- Submit attendance (re-submitting an already-submitted session edits it in place)

**Deliberately excluded**: the WhatsApp reminder-sending endpoints (`/assistant/whatsapp-template`, `/assistant/courses/{course}/reminder-recipients`) — the reference desktop app pairs these with a local WhatsApp Web automation sidecar, which isn't practical on Android/iOS. If you want a reminder feature later, the simplest mobile-friendly version is an intent/URL launch to `wa.me/<phone>?text=<message>` per recipient (one tap each, not bulk-automated).

## Running it

```
flutter pub get
flutter run                 # picks whatever device/emulator is connected
flutter build apk --release # Android release build
flutter build ios --release # iOS - needs a Mac with Xcode, not buildable from this machine
```

Change the API target in `lib/config.dart` if you ever point this at a different teacher's platform (the same `/api/assistant/*` surface exists identically on every LearnQuad-lineage platform on this account).

## Test account

A QA test assistant account exists on production for trying the app:
- Email: `qa-test-assistant@example.com`
- Password: `TestAssist123!`

Delete it (and its `assistant_profiles` row) once you've set up real assistant accounts for actual staff, or keep it around for future testing — your call.

## What's not done yet

- **iOS build/signing**: the project is structured for iOS (`ios/` platform folder, camera permission string) but was only ever compiled for Android on this Windows machine — no Mac/Xcode available here. Building and signing for TestFlight/App Store needs a Mac with Xcode and an Apple Developer account.
- **App icon**: still the default Flutter icon — swap `android/app/src/main/res/mipmap-*/ic_launcher.png` (and the iOS equivalent) for real branding before distributing.
- **Release signing (Android)**: `flutter build apk --release` currently uses the debug keystore. Set up a real signing config in `android/app/build.gradle.kts` before publishing to the Play Store.
- **WhatsApp reminders**: see above — not built, by design, pending a decision on the mobile-friendly approach.
