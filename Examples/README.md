# SendspinKit Examples

Standalone example apps demonstrating SendspinKit features. Each is a self-contained Swift package that can be copied as a starting point for your own project.

## Examples

| Example | What It Demonstrates |
|---------|---------------------|
| **DiscoveryExample** | mDNS/Bonjour server discovery on the local network |
| **MetadataClient** | Display-only client showing track info and playback state |
| **ControllerClient** | Interactive terminal remote control (play/pause/skip/volume) |
| **MultiCodecPlayer** | PCM/Opus/FLAC format negotiation and codec selection |
| **ErrorRecovery** | Reconnection with exponential backoff and error classification |
| **ClockSyncDiagnostics** | Real-time Kalman filter clock sync diagnostics dashboard |
| **CLIPlayer** | Full-featured player with status display |
| **VisualizerClient** | macOS SwiftUI visualizer with bounded deadline-aware frame delivery |

## Learning Path

**Getting started** — Run DiscoveryExample to find servers on your network, then MetadataClient to see what's playing.

**Adding control** — ControllerClient shows how to send playback commands. MultiCodecPlayer demonstrates format negotiation.

**Production patterns** — ErrorRecovery shows robust reconnection with exponential backoff and explicit retryable/fatal error classification. ClockSyncDiagnostics polls `SendspinClient.currentClockSyncStats()` on a timer and renders an ANSI dashboard, classifying sync quality via the public `ClockSyncQuality` enum so every consumer agrees on what "good" means.

**Full implementation** — CLIPlayer ties everything together in a complete player.

## Running

Each example is a standalone SPM package. From the example directory:

```bash
cd Examples/DiscoveryExample
swift run
```

All examples (except DiscoveryExample) accept `--server <url>` or `--discover` to find a server:

```bash
# Connect to a specific server
swift run MetadataClient --server ws://192.168.1.100:8927/sendspin

# Auto-discover on the local network
swift run MetadataClient --discover

# Discovery with custom timeout
swift run MetadataClient --discover --timeout 10
```

Use `--help` on any example for its full option list. VisualizerClient is a macOS SwiftUI app and accepts an explicit URL or discovery:

```bash
cd Examples/VisualizerClient
swift run VisualizerClient --server ws://192.168.1.100:8927/sendspin
swift run VisualizerClient --discover --timeout 5
```

VisualizerClient uses a generated process-local identity. Add `--pairing` for explicit paired-only
access; persist the displayed pairing token in a real application.

## Requirements

- macOS 14.0+
- Swift 6.2+
- A running [Sendspin-compatible server](https://github.com/Sendspin/spec) on the local network
