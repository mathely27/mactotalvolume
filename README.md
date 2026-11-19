# Mactotalvolume

A lightweight macOS menu bar app for changing the volume of individual audio processes.

## Download and install

[Download the universal DMG](dist/Mactotalvolume-0.1.0-universal.dmg) for Apple silicon and Intel Macs running macOS 14.2 or later.

Open the DMG, drag `Mactotalvolume.app` onto the `Applications` shortcut, then open it from Applications. If macOS blocks the first launch, check **System Settings → Privacy & Security** for an **Open Anyway** option. When macOS asks for System Audio Recording access, allow it so the app can control audio.

The app is ad-hoc signed and not notarized, so Gatekeeper may show a first-open warning. To rebuild the DMG from source, run:

```sh
./scripts/package-dmg.sh
```

## Build and launch

Run this from the project folder in Antigravity's terminal:

```sh
./scripts/build-app.sh
```

The script closes an older `VolumeMixer` process, replaces the app bundle under `.build`, and launches one fresh copy. The app uses Core Audio process taps (macOS 14.2+) and asks macOS for System Audio Recording permission when first used.

Each active Core Audio process gets its own icon and slider. Browsers may use separate helper processes for audio, but macOS does not expose browser tab titles through Core Audio, and a helper process can serve more than one tab.
