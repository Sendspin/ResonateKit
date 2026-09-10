# Events and Observable State

React to server events and bind client state to your UI.

## Overview

SendspinKit provides two complementary ways to observe state: an event stream for discrete occurrences and observable properties for continuous UI binding.

## Event stream

``SendspinClient/events`` is an `AsyncStream<ClientEvent>` that emits significant control-plane events. Binary role payloads are delivered through ``SendspinClient/audioChunks``, ``SendspinClient/artwork``, and ``SendspinClient/visualizerData``:

| Event | When |
|-------|------|
| ``ClientEvent/serverConnected(_:)`` | Handshake complete, roles activated |
| ``ClientEvent/pairingCodeChanged(_:)`` | Dynamic pairing code emitted or cleared (`nil`) |
| ``ClientEvent/pairingAttemptEnded(_:)`` | Code-based pairing attempt ends with a ``PairAbortReason`` |
| ``ClientEvent/streamStarted(_:)`` | Audio stream begins with format info |
| ``ClientEvent/streamFormatChanged(_:)`` | Codec or sample rate changed mid-stream |
| ``ClientEvent/streamEnded(roles:)`` | Server stopped one or more audio streams |
| ``ClientEvent/streamCleared(roles:)`` | Buffers flushed without ending the stream |
| ``ClientEvent/metadataReceived(_:)`` | Track metadata updated |
| ``ClientEvent/groupUpdated(_:)`` | Group membership or playback state changed |
| ``ClientEvent/controllerStateUpdated(_:)`` | Supported commands, group volume/mute changed |
| ``ClientEvent/colorStateUpdated(_:)`` | Audio-derived colors updated |
| ``ClientEvent/colorStateCleared`` | Server cleared the color role state |
| ``ClientEvent/artworkStreamStarted(_:)`` | Artwork stream configuration received; image bytes arrive through ``SendspinClient/artwork`` |
| ``ClientEvent/outputDelayChanged(milliseconds:)`` | Server changed the player's output delay |
| ``ClientEvent/disconnected(reason:)`` | Connection ended |

The stream is consumed exactly once. Start iterating before connecting:

```swift
Task {
    for await event in client.events() {
        handleEvent(event)
    }
}
try await client.connect(to: serverURL)
```

## Observable properties

``SendspinClient`` is `@Observable`, making these properties directly usable in SwiftUI views without wrappers:

- ``SendspinClient/connectionState`` — current connection lifecycle state
- ``SendspinClient/currentStreamFormat`` — active audio format, or `nil`
- ``SendspinClient/currentVolume`` — player volume (0-100)
- ``SendspinClient/currentMuted`` — mute state
- ``SendspinClient/outputDelayMs`` — output delay in milliseconds
- ``SendspinClient/currentColorState`` — latest audio-derived color state, or `nil` when cleared

These properties update on the main actor and trigger SwiftUI view updates automatically. A
``ColorState`` includes both its raw server timestamp and a local absolute display time when clock
sync is ready. Most UI consumers can apply colors immediately; synchronized consumers can schedule
the update using ``ColorState/localDisplayTime``.

## Completion and physical timing

A command method returning successfully means that SendspinKit accepted and sent the encrypted
command. It does not mean that the server acknowledged the command, that application audio has
started or ended, or that a sample is audible. Use the resulting control events and output telemetry
when the UI needs an observed state transition.

``SendspinClient/outputDelayMs`` describes physical downstream delay after submission to the output
path. Changing it retimes pending audio; samples already submitted cannot be rewritten. Consequently
an output-delay change is not instantaneous acoustic convergence. The adjusted timing becomes
observable as the retimed pipeline reaches the downstream device.

For visualizers, ``PresentationClock`` and ``PresentationInstant`` are a monotonic scheduling domain,
not a display-photon clock. ``PresentationClock/sleep(until:)`` prevents early submission and
``VisualizerFrame/isValid`` checks stream generation at the due instant, but a CoreVideo display-link
submission does not guarantee the next screen refresh or exact photon timing. Consumers must not
claim refresh synchronization without an independently measured clock mapping.
