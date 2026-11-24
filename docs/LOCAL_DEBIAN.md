# Local Debian runtime (work in progress)

A Debian Trixie rootfs runs under PRoot on the phone. The board, the pane,
the answer guards and the design system stay exactly as they are: this is a new
`HerdrTransport`, not a new UI and not a terminal emulator inside Flutter.

## Shape

```
Flutter UI (unchanged)
  → PaneViewModel / MachineConnection / HerdrApi (unchanged)
  → LocalTransport (app/lib/data/services/local_transport.dart)
      ping, session.snapshot, pane.read, pane.send_text,
      pane.send_keys, pane.send_input, events.subscribe
  → LocalPtyPlatform (Dart interface)
  → Android plugin: foreground service + PTY + PRoot + rootfs
```

`LocalTransport` is deliberately discardable. When `herdr-core` runs on the
device, a different `HerdrTransport` takes its place and nothing above the
transport changes.

## Decisions

- The runtime persists in an Android foreground service. It survives the app
  going to the background and Activity recreation. It does **not** survive
  Android killing the app process; a killed runtime is shown as stale, never
  as live.
- The rootfs is downloaded on first use over HTTPS with size and SHA-256
  checks, like ThothTerm's `fdroid` flavour. It is a GitHub Release asset of
  this repository; the URL and hash are pinned in `distro.properties`.
- The pane shows shell output with SGR colours, not a full terminal emulator.
  `vim`, `htop` and other alternate-screen programs will not render correctly.
  This is intentional: adding a cursor/mouse emulator would change the pane's
  design and its tests.
- The local runtime has no SFTP, no exec channel and no web bridge. Those
  methods fail loudly with `supportsFiles = false` and fatal transport errors.

## Provenance and licence

- This repository is a fork of `tuan3w/herdr-mobile` and stays GPL-3.0-only.
- The PTY JNI sources and the rootfs manager come from `Lord1Egypt/AndroidThothTerm`
  (Apache-2.0). Keep its `NOTICE` and file headers.
- PRoot is GPL-2.0 and talloc is LGPL-3.0. They run as a separate executable
  in `nativeLibraryDir`, never linked into the app binary. The release must
  carry the pinned submodule commits, the local patches and `build-proot.sh`
  so the corresponding source is available.
- The rootfs contains unmodified Debian packages; their copyrights ship
  inside the image at `/usr/share/doc/*/copyright`.

## Status (unverified — no Android/Flutter toolchain in this workspace)

Implemented: the transport contract and its API shim with fake-PTY tests; the
PTY JNI layer and a Kotlin plugin that currently spawns `/system/bin/sh` as a
spike; the main-isolate bridge that keeps platform channels off the transport
worker; a `MachineKind.local` profile added on first real start; factory and
connection wiring. Not implemented yet: the foreground service, the PRoot and
rootfs port, the setup screen, UI for adding/removing the local machine, and
the release workflow changes. Nothing here has been analysed, tested on a
device or built into an APK.

## Build and release (planned)

1. `tool/check.sh` — Flutter 3.47, `flutter analyze`, `flutter test`.
2. Build one universal ARM APK; signing secrets are absent, so the first
   releases are unsigned. Never commit a keystore or `key.properties`.
3. Attach the APK, `SHA256SUMS`, the rootfs archive and its `SHA256SUMS` to a
   `v0.1.x` GitHub Release. The tag's changelog section becomes the notes.
4. Version line stays `0.1.x`; bump `pubspec.yaml` and `app_info.dart`
   together and keep `+N` increasing above 5036.
