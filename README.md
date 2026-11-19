# Mactotalvolume

A lightweight macOS menu bar app for changing the volume of individual audio processes.

## Build and launch

Run this from the project folder in Antigravity's terminal:

```sh
./scripts/build-app.sh
```

The script closes an older `VolumeMixer` process, replaces the app bundle under `.build`, and launches one fresh copy. The app uses Core Audio process taps (macOS 14.2+) and asks macOS for System Audio Recording permission when first used.

Each active Core Audio process gets its own icon and slider. Browsers may use separate helper processes for audio, but macOS does not expose browser tab titles through Core Audio, and a helper process can serve more than one tab.
