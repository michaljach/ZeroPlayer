# ZeroPlayer

iOS video player with AirPlay support. Plays MP4, MKV, and other container formats locally via mpv, and streams to AirPlay receivers via on-the-fly HLS remuxing.

## Architecture

- **Local playback**: mpv (via [MPVKit](https://github.com/mpvplayer/MPVKit)) with hardware-accelerated decoding
- **AirPlay playback**: AVPlayer consuming HLS from a local HTTP server
- **State management**: [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA)

```
┌──────────────┐
│  PlayerView  │
└──────┬───────┘
       │
  ┌────┴────┐
  │ mpv     │  ← Local playback (always mounted, hidden during AirPlay)
  │ AVPlayer│  ← AirPlay playback via HLS
  └────┬────┘
       │
┌──────┴───────────┐
│  HLSProxyService │  ← Orchestrates HLS generation
└──────┬───────────┘
       │
  ┌────┴────────────┐
  │  FFmpegService  │  ← Remuxes segments + extracts subtitles (FFmpeg C API)
  │  LocalHTTPServer│  ← Serves HLS on localhost:8080 (Network.framework)
  └─────────────────┘
```

### How AirPlay Works

When AirPlay activates:

1. mpv's video track is disabled (view hidden with `opacity(0)`)
2. `FFmpegService` generates an HLS playlist with 10-second MPEG-TS segments
3. Segments are remuxed on-demand from the source file using FFmpeg C API -- no re-encoding for compatible codecs
4. Incompatible audio (Opus, Vorbis, FLAC, DTS) is transcoded to AAC in real-time
5. `LocalHTTPServer` serves the playlist and segments to AVPlayer
6. AVPlayer streams to the AirPlay receiver
7. Subtitles are extracted via FFmpeg and served as segmented WebVTT

When AirPlay deactivates, playback resumes on mpv at the current position.

## Requirements

- Xcode 16+
- iOS 18+
- Swift Package Manager (dependencies resolve automatically)

## Building

1. Open `zeroplayer.xcodeproj` in Xcode
2. Wait for SPM to resolve dependencies (MPVKit, TCA)
3. Build and run on a physical device (AirPlay requires a real device)

### MPVKit Modulemap Patch

MPVKit's `Libavutil` modulemap includes `hwcontext_amf.h` which references `<AMF/core/Factory.h>` (unavailable on iOS). After a clean build or SPM re-resolve, you may need to patch the modulemaps in DerivedData:

```bash
find ~/Library/Developer/Xcode/DerivedData/zeroplayer-*/SourcePackages \
  -name "module.modulemap" -path "*/Libavutil/*" \
  -exec sed -i '' '/hwcontext_amf\.h/d' {} \;
```

## Project Structure

```
zeroplayer/
  App/                    # App entry point, root feature
  Features/
    FilePicker/           # File selection UI
    Player/
      AirPlay/            # AirPlay route detection, activation/deactivation
      Subtitle/           # Subtitle track management
      PlayerFeature.swift # Core player state & logic (TCA Reducer)
      PlayerView.swift    # Player UI (mpv + AVPlayer views)
  Models/                 # VideoInfo, SubtitleTrack, WebVTTParser
  Services/
    FFmpegService.swift   # FFmpeg C API: remuxing, analysis, subtitle extraction
    HLSProxyService.swift # HLS orchestration, segment caching
    LocalHTTPServer.swift # Network.framework HTTP server
    MPVPlayerController.swift  # mpv wrapper
  Clients/                # TCA dependency clients
```
