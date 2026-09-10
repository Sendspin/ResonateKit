# Visualizer delivery

`SendspinClient.acquireVisualizerFrames()` returns the single bounded
`VisualizerFrameSubscription`; it is not an unbounded `AsyncStream`. Its mailbox counts each retained
frame as the visualizer wire size:
9 bytes for the type and timestamp plus the payload bytes. A frame larger than the
configured `VisualizerConfiguration.bufferCapacity` is dropped. When a frame would
exceed the remaining budget, the oldest retained frames are dropped first; this keeps
a slow consumer close to the live display while preserving FIFO order among frames
that remain.

Frames whose local display time has passed are dropped both when they arrive and when
a consumer resumes. `stream/clear` and `stream/end` invalidate queued frames and immediately release their
mailbox storage. Session retirement and client close also release all retained bytes. A valid new stream
resets the timestamp floor. An in-place `stream/start` preserves the floor, so frames
cannot rewind unless the protocol supplies an explicit clear or new stream.

The mailbox has one in-flight read per iterator and never creates a producer task.
A second iterator returns `nil`; concurrent reads on one iterator are unsupported.
The message loop offers frames non-blockingly; it never waits for the public consumer.

The negotiated `rateMax` remains one scalar for all periodic types (`loudness`,
`f_peak`, and `spectrum`). `beat` and `peak` remain event-driven and are not throttled
by that scalar.

## Display scheduling

`VisualizerFrame.presentationTime` is a `PresentationInstant` in the monotonic domain shared by
`PresentationClock`. Never translate it through wall-clock `Date` or schedule a draw from arrival
order. A consumer may use `eligibilityForScheduling(at:)` while a frame is still in the future and
`PresentationClock.sleep(until:)` to avoid drawing early. At the display callback, it should capture
one fresh clock instant and perform the final `isValid` generation check immediately before
submitting pixels. `isValid` is intentionally independent of the presentation deadline: a due frame
can remain valid, while `eligibilityForScheduling(at:)` is only the pre-deadline scheduling gate.

`Examples/VisualizerClient` demonstrates a bounded consumer: one FIFO task awaits each frame's
presentation deadline, then a per-type latest-due mailbox feeds an AppKit CoreVideo display-link
tick. A display-link submission is not a guarantee of screen-photon timing or exact refresh
synchronization, because this example does not claim a display-link-to-presentation-clock mapping.
Do not convert instants through wall time or retain an unbounded app-side queue.
