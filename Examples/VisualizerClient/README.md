# VisualizerClient

A minimal macOS SwiftUI visualizer consumer. It requests loudness and spectrum frames,
waits for each frame's typed presentation deadline, checks generation validity, and renders
only the latest due frame on an AppKit CoreVideo display-link tick.

The library mailbox is bounded by `VisualizerConfiguration.bufferCapacity`. The app adds a
second bounded presentation queue with the same byte budget. Its consumer ingests frames
immediately (it never sleeps on a frame deadline), evicts the oldest queued bytes when full,
and keeps the newest due frame for each rendered type. Slow display ticks therefore preserve
all due types without allowing stale data or an unbounded per-frame task queue.

## Run

From the repository root:

```bash
cd Examples/VisualizerClient
swift run VisualizerClient --server ws://127.0.0.1:8927/sendspin
```

Use mDNS discovery instead:

```bash
swift run VisualizerClient --discover --timeout 5
```

The app accepts `--name <name>` to set its client name. Add `--pairing` for paired-only access with
display code presentation. The example runs on an ephemeral demo device, so its identity and pairing
state are process-local; a real host application opens a durable device with
`SendspinDevice.open(storage:)` instead.
The pairing panel displays the current immutable attempt snapshot, treats the peer ID as unverified
until trust succeeds, opens the authorization window with the captured `PairingAttemptID`, and
cancels with that exact ID. A stale button action is reported instead of retargeting a newer attempt.

Close the window with the **Close client** button or the window close action. The app cancels the
visualizer subscription before awaiting `SendspinClient.close()`.

## Timing boundary

`PresentationClock` and `PresentationInstant` stay in SendspinKit's monotonic presentation domain;
the app never converts them through `Date` or wall time. A successful visualizer submission at a
CoreVideo display-link tick means the app submitted the latest due value to the view model. It does
not guarantee the next screen refresh or screen-photon time, and this example does not claim exact
refresh synchronization or a display-link-to-presentation-clock mapping.
