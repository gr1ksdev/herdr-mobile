# Third-party notices

## ThothTerm PTY layer (Apache-2.0)

The following files are adapted from `Lord1Egypt/AndroidThothTerm`,
originally from TermOne Plus (Roumen Petrov), itself derived from Jack
Palevich's Terminal Emulator for Android:

- `app/android/app/src/main/cpp/{CMakeLists.txt,compat.c,compat.h,grantpt.c,process.c,registration.c,registration.h,termio.c}`
- `app/android/app/src/main/java/com/thothterm/{Process.java,TermIO.java}`

They are licensed under the Apache License, Version 2.0. The original
copyright notices and licence headers are retained in each file. The
upstream project's `NOTICE` reads:

> This product includes software developed by Roumen Petrov and contributors
> (TermOne Plus), Jack Palevich (Terminal Emulator for Android) and the
> Android Open Source Project.

## Planned with the PRoot/rootfs port

- **PRoot** (GPL-2.0), pinned submodule commit plus the local patches and
  `build-proot.sh` must ship with every release that includes its binary.
- **talloc** (LGPL-3.0-or-later) and **libandroid-shmem** (BSD-3-Clause) are
  built as separate libraries, never linked into the Flutter app binary.
- The Debian rootfs carries unmodified packages; their copyright texts ship
  inside the image at `/usr/share/doc/*/copyright`.

The app remains GPL-3.0-only (see `LICENSE`). Apache-2.0 code is compatible
with GPL-3.0; the copyleft libraries stay separate executables.
