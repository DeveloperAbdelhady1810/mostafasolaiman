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

A QA test assistant account exists on production for trying the app. Its credentials are deliberately **not** kept in this repo (the repo is public); ask the platform owner for them. Delete the account (and its `assistant_profiles` row) once real assistant accounts exist for actual staff, or keep it for future testing.

## Scanning student codes

The scanner stays open so a whole line of students can be scanned without reopening the camera; each scan gives a
banner and a haptic tick, and "Done" returns to the roster.

- **Rotating codes** (new Mostafa Solaiman student app): `MSQ1:{student_no}:{counter}:{mac}`, changes every 30 s.
  The phone cannot check it (the secret never leaves the student's phone), so each scan is verified by the server
  through `POST /api/assistant/attendance/bulk`; only verified students are marked present, and the student gets an
  "attendance recorded" push. If the phone is offline the scan is queued (and shown as "Waiting to be verified"),
  sent when the connection is back, and always flushed before Submit. Detection times use the server's clock
  (learnt from the HTTP `Date` header), so a wrong phone clock does not break verification.
- **Old static ID codes** (`LQ-000123`): still accepted exactly as before, matched against the roster.
- The feature is controlled by the server (`GET /api/assistant/ble/features`); while it is off, rotating codes are refused
  with a clear message and the old flow is unchanged.

## Classroom Radar (Bluetooth)

When the server has the feature on (`GET /api/assistant/ble/features`), the roster screen shows **Classroom Radar**.
Students' phones broadcast their rotating code over Bluetooth for 60 s after opening the student app; the radar lists
everyone in range (name from the roster, signal bars, one tick + vibration per new student), you can untick anyone
detected by mistake (e.g. through a wall), adjust the range slider (default -75 dBm, from the server), and **Confirm**
sends them to `POST /api/assistant/attendance/bulk` (`method=ble`, with the signal strength). Only students the server
verifies are marked present; rejections are listed with a reason and can still be added with Scan QR / Add Walk-in.
Offline confirmations are saved, shown as "Waiting to be verified" and sent before Submit.

Each detected student is answered with a short Bluetooth "I heard you" reply (the student's phone then plays its tick):
one reply at a time, up to 3 per student per broadcast, 8 s apart, in case the first one is missed.

- Android 11 and older: Bluetooth scanning needs Location permission and Location switched on. Android 12+ / iOS: just
  the Bluetooth ("Nearby devices") permission.
- A student phone's signal strength is a hint (about +-10 dB between phones), not proof; the assistant still counts the
  class. Fake packets can only produce a rejected entry, never a present student.
- Test builds against a local mock server (never ship these): `--dart-define=API_BASE=http://10.0.2.2:8765/api`.

## What's not done yet

- **iOS build/signing**: the project is structured for iOS (`ios/` platform folder, camera permission string) but was only ever compiled for Android on this Windows machine — no Mac/Xcode available here. Building and signing for TestFlight/App Store needs a Mac with Xcode and an Apple Developer account.
- **App icon**: still the default Flutter icon — swap `android/app/src/main/res/mipmap-*/ic_launcher.png` (and the iOS equivalent) for real branding before distributing.
- **Release signing (Android)**: `flutter build apk --release` currently uses the debug keystore. Set up a real signing config in `android/app/build.gradle.kts` before publishing to the Play Store.
- **WhatsApp reminders**: see above — not built, by design, pending a decision on the mobile-friendly approach.
