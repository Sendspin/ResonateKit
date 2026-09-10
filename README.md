# SendspinKit

A Swift client library for the [Sendspin Protocol](https://github.com/Sendspin/spec) — enabling synchronized multi-room audio playback on Apple platforms.

## Features

- **Player Role** — Synchronized audio playback with microsecond-precision clock sync
- **Controller Role** — Play, pause, skip, volume, shuffle, repeat across device groups
- **Metadata Role** — Track info, artwork URLs, and playback progress
- **Artwork Role** — Album art delivery with format and resolution negotiation
- **Visualizer Role** — Configurable beat, loudness, peak, and spectrum data
- **Color Role** — Synchronized album and audio-derived color themes
- **Auto-discovery** — mDNS/Bonjour server discovery with continuous or one-shot modes
- **Multi-codec** — PCM, Opus, and FLAC support with seamless mid-stream format switching
- **Clock Sync** — Kalman filter time synchronization with drift tracking and adaptive forgetting
- **Hardware & Software Volume** — Perceptual gain curve with per-device or per-queue control

## Requirements

- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Swift 6.2+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Sendspin/SendspinKit.git", from: "1.0.0")
]
```

## Quick Start

A `SendspinIdentity` is the device's long-lived cryptographic identity. The host app owns its
secret-key persistence: load `secretKeyBytes` from the Keychain (or another protected store) on
launch, and save the bytes from a newly generated identity before connecting. Rotating the secret
changes the device's `clientId`.

Pairing is also host-owned. Pass a `PairingConfiguration` with an app-backed
`PairingRecordStore` when pairing should survive process restarts. The default in-memory store is
useful for tests and demonstrations, but is not persistent. Treat the pairing PSK and the resulting
`PairingToken.string` as secrets; display or encode the token as a QR code only through a trusted
setup flow.

```swift
import SendspinKit

// Create a player client
let identity = SendspinIdentity.generate()
let pairing = PairingConfiguration() // Pass an app-backed PairingRecordStore in production.
let token = PairingToken(clientKey: identity.publicKeyBytes, pairingPsk: pairing.pairingPsk)
print("Pairing token: \(token.string)") // display or encode as a QR code

let client = try SendspinClient(
    identity: identity,
    name: "Living Room Speaker",
    roles: [.playerV1],
    playerConfig: try PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
            try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
        ],
        requiredLeadTimeMs: 100,
        minBufferMs: 500
    ),
    unpairedAccessEnabled: false,
    pairing: pairing
)

// Discover and connect to the first server found
let servers = try await SendspinClient.discoverServers(timeout: .seconds(5))
if let server = servers.first {
    try await client.connect(to: server.url)
}

// React to events
for await event in client.events() {
    switch event {
    case let .serverConnected(info):
        print("Connected to \(info.name); trust: \(info.trustLevel)")
    case let .paired(serverId):
        print("Paired with \(serverId)")
    case let .streamStarted(format):
        print("Playing \(format.codec) at \(format.sampleRate)Hz")
    case let .metadataReceived(metadata):
        print("Now playing: \(metadata.title ?? "Unknown")")
    case .audioOutputChanged, .outputFormatStatusChanged, .streamingFailed,
         .streamFormatChanged, .streamEnded, .streamCleared, .groupUpdated,
         .controllerStateUpdated, .colorStateUpdated, .colorStateCleared,
         .artworkStreamStarted, .outputDelayChanged, .lastPlayedServerChanged:
        break
    case let .disconnected(reason):
        print("Disconnected: \(reason)")
    }
}
```

`ServerInfo.trustLevel` reports whether the active session is backed by a pairing record
(`.user`) or is unpaired (`.none`). Set `unpairedAccessEnabled` to `false` when every server must
be paired. Enabling unpaired access deliberately permits unauthenticated server access, so an
on-path attacker can impersonate a server.

Dynamic player, artwork, and visualizer preferences are sent in `client/state`. Use
`setPlayerFormatPreference(_:)` or `setPlayerFormatPreference(codec:channels:sampleRate:bitDepth:)`
to select a supported audio format, and `setArtworkChannelPreference(channel:preference:)` with
`ArtworkChannelPreference.set(source:format:width:height:)` or `.disable` to update an artwork
channel. These preferences can be changed while connected and apply to the active or next stream.

### Group membership and external sources

A client can leave its current group without requiring the controller role:

```swift
try await client.leaveGroup()
```

This sends `client/leave` with an empty payload. The server stops playback for this client and
places it in a solo group; the client does not invent or clear local group state, and returning to
the previous group requires an explicit server-directed group change. For non-interruptible local
playback, use `enterExternalSource()` and `exitExternalSource()` instead. Exiting an external source
makes the client available again but does not automatically rejoin its previous group.

## Pairing codes

Pairing-code flows are app-facing setup hooks. Enable a method in `PairingConfiguration`, then
listen to `SendspinClient.events()` for `ClientEvent.pairingCodeChanged(_:)`,
`ClientEvent.pairingAttemptEnded(_:)`, and `ClientEvent.paired(_:)`. Each event carries a
`PairingAttemptSnapshot`; keep its `id` with the UI state that displayed its code.

- Dynamic pairing emits a `PairingCodeEmission` with `format == .digits` and a contiguous six-digit
  `payload`, or with `format == .qrCode` and a complete version-one `SP:1` `payload`. Display or
  speak the value from the app; presentation grouping and QR image generation remain app
  responsibilities. A `nil` `code` clears any displayed code.
- Call `try await client.openPairingWindow(for: snapshot.id)` from the app's physical-gesture or
  equivalent operator-confirmation hook. It records or consumes the connection-owned window and
  returns without waiting for pairing to finish.
- Cancel only the attempt represented by the ID captured with the rendered snapshot:

  ```swift
  // `renderedPairing` is the immutable snapshot captured by the UI row/button.
  let displayedAttemptID = renderedPairing?.id
  if let displayedAttemptID {
      do {
          try await client.cancelPairing(attemptID: displayedAttemptID)
      } catch SendspinClientError.stalePairingAttempt {
          // The displayed attempt ended; do not retarget a newer attempt.
      }
  }
  ```

  `PairingAttemptID` is opaque. A retry retains its ID; a later activation receives a new one.
  `client.currentPairing` retains the latest terminal snapshot until another attempt starts.
  `client.pairingWindow` is the observable authorization window for that attempt and becomes `nil`
  when it expires or closes; its `expiresAt` is UI state, not a trust assertion.
  `snapshot.peer.id` is unverified while `snapshot.peer.trustLevel == .none`; only successful
  pairing establishes `.user` trust. The authorization window is operator consent, not server trust.
  Handle terminal `snapshot.phase` values such as
  `.ended(.pairingCodeMismatch)`, `.ended(.userCancelled)`, `.ended(.attemptTimeout)`, and
  `.ended(.methodNotSupported)` as outcomes rather than assuming cancellation succeeded.

Static pairing uses `PairingConfiguration(staticPairingCode:staticPairingCodeEnabled:)`. The host
must provision and persist a device-unique eight-digit ASCII decimal code; never ship a fixed
shared default. Hosts rotate the code through their local pairing configuration; the secret is
never exposed in client events. Static codes are not emitted as `pairingCodeChanged` events.

Dynamic pairing binds the code to the physical device-presence flow, so a relay cannot reuse a code
across different Noise handshakes. Static pairing authenticates the code but does not provide that
presence binding: if the static code leaks, an on-path attacker can use it to perform a
man-in-the-middle pairing flow.

### Controller + Metadata

```swift
let controller = try SendspinClient(
    identity: SendspinIdentity.generate(),
    name: "Kitchen Display",
    roles: [.controllerV1, .metadataV1]
)

try await controller.connect(to: serverURL)

// Control playback
try await controller.play()
try await controller.next()
try await controller.setGroupVolume(75)
try await controller.setShuffle(true)
```

### Color Display

```swift
import SendspinKit
import SwiftUI

extension Color {
    init(_ rgb: RGBColor) {
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: 1
        )
    }
}

let colorDisplay = try SendspinClient(
    identity: SendspinIdentity.generate(),
    name: "Kitchen Display",
    roles: [.colorV1]
)

struct NowPlayingView: View {
    let client: SendspinClient

    var body: some View {
        PlayerControls()
            .background(client.currentColorState?.backgroundDark.map(Color.init) ?? .black)
            .foregroundStyle(client.currentColorState?.onDark.map(Color.init) ?? .white)
    }
}
```

`currentColorState` is observable and contains the latest accumulated theme. Each state includes
`serverTimestamp` and, once clock synchronization is ready, `localDisplayTime` for consumers that
schedule color changes alongside audio, artwork, or visualizer updates.

### Visualizer Configuration

Configure the visualizer role when creating the client. The requested types, maximum update rate,
and optional spectrum parameters are published in `client/state`; the server's negotiated types,
rate, conditional `tracks_downbeats`, and spectrum parameters are exposed by the
`.visualizerStreamStarted` event and `currentVisualizerStreamConfiguration`. Acquire the single
bounded data-plane consumer with `try client.acquireVisualizerFrames()`. Each `VisualizerFrame`
contains its type, raw payload, typed `presentationTime`, and the negotiated configuration that
validated it. The subscription drops stale frames and invalidates queued frames when a stream or
session ends; it never creates an unbounded producer queue.

Use `PresentationClock` and `PresentationInstant` for scheduling. A frame is eligible only while
`frame.eligibilityForScheduling(at: clock.now)` is true; after sleeping until its presentation
instant, capture a fresh instant and call `frame.isValid` immediately before submitting it to the
view model or display tick. `isValid` checks stream generation only, so a due frame can remain valid;
its deadline is a scheduling decision, not a lifetime check. Do not convert presentation instants
through wall clock time or draw a frame early. See `Examples/VisualizerClient` for a bounded SwiftUI
consumer; a display-link submission is not a guarantee about screen-photon timing.

```swift
let visualizer = try SendspinClient(
    identity: SendspinIdentity.generate(),
    name: "Kitchen Display",
    roles: [.visualizerV1],
    visualizerConfig: try VisualizerConfiguration(
        types: [.loudness, .spectrum],
        rateMax: 30,
        spectrum: SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 60, fMax: 16_000)
    )
)
```

### Continuous Discovery

```swift
let discovery = try await SendspinClient.discoverServers()
for await servers in discovery.servers {
    print("Found \(servers.count) server(s):")
    for server in servers {
        print("  \(server.name) at \(server.url)")
    }
}
```

## Codec Support

- **PCM** — Uncompressed audio up to 192kHz/32-bit (zero-copy passthrough)
- **Opus** — Low-latency lossy compression (8-48kHz, optimized for real-time)
- **FLAC** — Lossless compression with hi-res support (up to 192kHz/24-bit)

All codecs output normalized int32 PCM for consistent pipeline processing.

## Audio Synchronization

SendspinKit uses a Kalman filter for clock synchronization and timestamp-based audio scheduling:

- **Clock Sync** — Full 2D covariance Kalman filter with adaptive forgetting, drift SNR gating, and RTT floor
- **AudioScheduler** — Priority queue of audio chunks sorted by playback time
- **Playback Window** — Configurable tolerance for network jitter (default +/-50ms)
- **Sync Correction** — Frame-level drop/insert to maintain alignment without audible glitches

A successful command API call means that SendspinKit accepted and sent the encrypted command. It is
not a server acknowledgement and is not evidence that application audio has started, completed, or
become audible. Treat the subsequent state/event stream and audio output telemetry as separate
signals.

`outputDelayMs` models physical downstream delay after the client submits audio to its output path.
When the value changes, pending audio is retimed for the new delay and already submitted audio cannot
be rewritten. The command/event transition therefore does not create instantaneous acoustic
convergence: the new timing takes effect as the retimed pipeline reaches the downstream device.
Keep this distinction when measuring synchronization or presenting completion UI.

## Documentation

API documentation is available via DocC. Build it locally with:

```bash
swift package generate-documentation
```

## License

Apache 2.0
