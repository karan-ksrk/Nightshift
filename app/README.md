# Nightshift phone app (Phase 3)

Flutter/Android client for the Phase 2 server (`server.py`). See
`C:\Users\Karan\.claude\plans\meanwhile-file-is-copying-rosy-cocoa.md` (or
ask for the plan again) for the full design: local SQLite mirror, chunked
upload + resume algorithm, manual-delete platform risk, milestones.

Android only (`flutter create --platforms=android`) — no iOS/web/desktop
folders, matching the decision in the plan.

## Environment setup (already done on this machine, documented for next time)

`C:\Users\Karan` (the Windows user profile root) denies write access to its
own owning user -- only SYSTEM/Administrators have full control there. This
broke several tools that default to writing config/cache under the home
directory, in a way that's easy to misdiagnose as a network/TLS problem
(the errors look like "IO exception downloading manifest" / build failures,
not "permission denied"):

- Gradle's wrapper couldn't create `~/.gradle/wrapper/dists/...`
- `sdkmanager` couldn't create `~/.android/cache/...`
- `scoop` (Windows package manager) hit the same ownership issue

Fix applied: redirect each tool's home directory to `D:\dev`, which the
current user *can* write to, via **user-scope** environment variables (set
with `[Environment]::SetEnvironmentVariable(..., "User")`, so they persist
across sessions without touching system-wide config or `C:\Users\Karan`'s
permissions):

- `GRADLE_USER_HOME = D:\dev\gradle-home`
- `ANDROID_USER_HOME = D:\dev\android-home` (holds `.android`'s cache +
  the adb key pair, copied over from the original `~/.android`)
- Flutter SDK itself lives at `D:\dev\flutter` (not `~`), added to the user
  `PATH`.

Android SDK components (system Android Studio install) needed updating
too: `compileSdk 36` / `build-tools 28.0.3` / `ndk 28.2.13676358` weren't
present, and the *original* `cmdline-tools` (v17.0) was too old to install
them — replaced with a fresh download (v19.0) at
`C:\Users\Karan\AppData\Local\Android\Sdk\cmdline-tools\latest` (old one
kept alongside as `latest-old-17.0` in case anything still points at it).

**If a fresh terminal doesn't have these set** (new shell before Windows
reloads the user env, or a differently-configured tool), set for the
session:

```powershell
$env:Path = "D:\dev\flutter\bin;" + $env:Path
$env:GRADLE_USER_HOME = "D:\dev\gradle-home"
$env:ANDROID_USER_HOME = "D:\dev\android-home"
```

`flutter doctor` should report all green except a harmless "multiple adb
binaries" note (SDK's own vs. `D:\platform-tools\adb.exe`, both usable).
All SDK licenses are already accepted.

## Build

```
cd app
flutter build apk --debug
```

No device connected yet (`adb devices` empty) — next session, connect a
phone (USB debugging on) or start an emulator to actually run/test on.
