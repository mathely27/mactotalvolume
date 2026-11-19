# Volume Mixer for Mac

A small macOS menu bar app for controlling the volume of individual apps.

## Current part

The menu bar popup currently detects and lists apps that are sending audio. This confirms the Core Audio process discovery step. Per-app sliders are the next part: macOS routes those through Core Audio process taps, which require macOS 14.2 or later and the system's audio-capture permission.

## Run it

From this folder in Terminal:

```sh
swift run
```

The app appears as a speaker icon in the menu bar. Play audio in an app and open the icon to see it listed.

## Build a distributable app

This project currently runs from Swift Package Manager. We can add an `.app` bundle and signing setup after the volume engine works.
