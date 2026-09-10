# Getting Started

Connect to a Sendspin server and start playing audio in under 20 lines of code.

## Overview

SendspinKit manages the full protocol lifecycle automatically. You configure a client with your desired roles and formats, discover or accept a server connection, and the library handles clock synchronization, codec negotiation, and audio scheduling.

## Install the package

Add SendspinKit to your `Package.swift` or Xcode project:

```swift
dependencies: [
    .package(url: "https://github.com/sendspin/SendspinKit.git", from: "0.1.0")
]
```

## Create a client

A ``SendspinClient`` needs a ``SendspinIdentity``, display name, and at least one role. Players also need a ``PlayerConfiguration`` declaring supported audio formats. Artwork and visualizer roles likewise require their role configuration.

```swift
import SendspinKit

let client = try SendspinClient(
    identity: .generate(),
    name: "Kitchen Speaker",
    roles: [.playerV1, .metadataV1],
    playerConfig: try PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),
            try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 16),
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16),
        ],
        requiredLeadTimeMs: 100,
        minBufferMs: 500
    )
)
```

For artwork, provide an ``ArtworkConfiguration`` with one to four ``ArtworkChannel`` values;
use ``ArtworkChannelPreference`` and ``SendspinClient/setArtworkChannelPreference(channel:preference:)``
to change a channel while connected. For visualizer data, provide a ``VisualizerConfiguration``;
include ``SpectrumConfiguration`` whenever the requested types contain ``VisualizerType/spectrum``.
These role configurations seed the initial `client/state` snapshot; dynamic preference changes use the
corresponding state-preference APIs.

A visualizer consumer owns one bounded subscription. Consume frames FIFO, use the monotonic
``PresentationClock`` to await each future ``VisualizerFrame/presentationTime``, then check
``VisualizerFrame/isValid`` before handing the due value to the UI. `isValid` checks stream generation
only, so a due frame can remain valid; `eligibilityForScheduling(at:)` is the pre-deadline gate.
Never convert these instants through wall-clock time or retain an unbounded app queue.

```swift
let frames = try client.acquireVisualizerFrames()
let consumer = Task {
    var iterator = frames.makeAsyncIterator()
    let clock = PresentationClock()
    while let frame = await iterator.next() {
        if frame.eligibilityForScheduling(at: clock.now) {
            try await clock.sleep(until: frame.presentationTime)
        }
        guard frame.isValid else { continue }
        // Replace the latest due value for this type in a bounded UI mailbox.
        submitDueFrame(frame)
    }
}

// On shutdown: consumer.cancel(); frames.cancel(); await client.close()
```

A display-link submission is not a guarantee of the next screen refresh or screen-photon time; an
app must not claim exact refresh synchronization without an independently measured clock mapping.
See the runnable ``VisualizerClient`` example for a SwiftUI/AppKit implementation.

## Leave a group

Any client role can leave its current server group:

```swift
try await client.leaveGroup()
```

This sends `client/leave` with an empty payload. The server places the client in a stopped solo group;
SendspinKit does not invent or clear local group state, and returning to the previous group requires an
explicit server-directed group change. For non-interruptible local playback, use
``SendspinClient/enterExternalSource()`` and ``SendspinClient/exitExternalSource()``. Exiting an external
source makes the client available again but does not automatically rejoin its previous group.

## Connect to a server

There are two connection patterns:

### Client-initiated (discover servers)

Use ``ServerDiscovery`` to find Sendspin servers on the local network via mDNS:

```swift
let discovery = ServerDiscovery()
try await discovery.startDiscovery()

for await servers in discovery.servers {
    if let server = servers.first {
        try await client.connect(to: server.url)
        break
    }
}
```

### Server-initiated (advertise and accept)

Use ``ClientAdvertiser`` to publish your client on the network and let servers connect to you:

```swift
let advertiser = ClientAdvertiser(
    name: "Kitchen Speaker",
    port: SendspinDefaults.clientPort
)
try await advertiser.start()

for await connection in advertiser.connections {
    try await client.acceptConnection(connection)
    break
}
```

## Listen for events

``SendspinClient`` exposes an ``AsyncStream`` of ``ClientEvent`` values covering the full lifecycle:

```swift
for await event in client.events() {
    switch event {
    case .serverConnected(let info):
        print("Connected to \(info.name)")
    case .metadataReceived(let metadata):
        print("Now playing: \(metadata.title ?? "Unknown")")
    case .streamStarted(let format):
        print("Streaming \(format.codec) at \(format.sampleRate)Hz")
    case .disconnected(let reason):
        print("Disconnected: \(reason)")
    default:
        break
    }
}
```

## Pair with a code

Code-based pairing is coordinated by the host app. Pass a ``PairingConfiguration`` with the
method enabled, start consuming ``SendspinClient/events``, and retain the complete
``PairingAttemptSnapshot`` that drives the operator UI:

```swift
for await event in client.events() {
    switch event {
    case let .pairingCodeChanged(snapshot):
        if let code = snapshot.code {
            print("Pairing \(code.format.rawValue): \(code.payload)")
        }
    case let .pairingAttemptEnded(snapshot):
        print("Pairing attempt \(snapshot.id.rawValue) ended: \(snapshot.phase)")
    case let .paired(snapshot):
        print("Paired with \(snapshot.peer.name); trust: \(snapshot.peer.trustLevel)")
    default:
        break
    }
}
```

Call ``SendspinClient/openPairingWindow(for:)`` with the ID captured by the rendered snapshot when
the app receives its physical-gesture or other operator-confirmation signal. It returns after
recording or consuming the connection-owned window; it does not wait for the attempt. To cancel,
call ``SendspinClient/cancelPairing(attemptID:)`` with that same captured ID. A stale ID throws
``SendspinClientError/stalePairingAttempt(_:)`` and never retargets a newer attempt. The observable
``SendspinClient/currentPairing`` retains the latest terminal snapshot until a new attempt starts;
``SendspinClient/pairingWindow`` becomes `nil` when its authorization window expires or closes, and
its `expiresAt` is not a trust assertion. The peer ID is unverified while
``PairingPeer/trustLevel`` is `.none`; the authorization window is not proof of server trust. Dynamic
codes are six contiguous digits or a complete version-one `SP:1` token. If
the dynamic method includes a speaker output capability, the code emission also includes a validated
``DigitAudioPack``; the host app decodes and plays its clips. Static pairing instead requires the
host to provision and persist a device-unique eight-digit ASCII decimal code with
``PairingConfiguration/init(pairingPsk:store:enabled:dynamicPairingCodeEnabled:staticPairingCode:staticPairingCodeEnabled:digitAudio:)``;
the library never supplies a fixed default or emits that secret. Choose at most one code method in
``PairingConfiguration``. Dynamic pairing binds device presence, while a leaked static code is
exposed to man-in-the-middle pairing.

## Observe state in SwiftUI

``SendspinClient`` is `@Observable`, so its published properties work directly with SwiftUI:

```swift
struct PlayerView: View {
    let client: SendspinClient

    var body: some View {
        VStack {
            Text(client.connectionState == .connected ? "Connected" : "Disconnected")
            if let format = client.currentStreamFormat {
                Text("\(format.codec.rawValue) \(format.sampleRate)Hz")
            }
        }
    }
}
```

## Disconnect

```swift
await client.disconnect(reason: .clientShutdown)
```
