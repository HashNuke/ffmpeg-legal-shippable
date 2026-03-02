## ffmpeg-macos-legal-portable

Builds portable (macOS 14.0+) FFmpeg binaries **without GPL** and **without nonfree** features, with macOS hardware acceleration support (VideoToolbox).

## Build

Requirements:
- Xcode Command Line Tools (`xcode-select --install`)
- `make`, `curl`, `tar`

Run:
```bash
./build.sh
```

Output:
- `dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal/bin/ffmpeg`
- `dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal/bin/ffprobe`
- `dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal.tar.gz`

Useful env vars:
- `MIN_MACOS=14.0` (default: `14.0`)
- `FFMPEG_VERSION=8.0.1` (default: `8.0.1`)
- `BUILD_STAMP=YYYYMMDDHHMM` (default: current UTC)
- `BUILD_ID=123` (optional build number/id)
- `WORK_DIR=...`, `DIST_DIR=...`, `JOBS=...`

## Notes

Prompt that was used to generate the initial build script

```
The user's computer may not have everything needed for dynamic libs. So please give me a script that

* bulids ffmpeg+ffprobe portables on my machine macos v15.5 that works on other machines from macos v14.0.
* disabled gpl
* disabled nonfree
* portable on other user's machine without assuming they have the dynamic libs
```
