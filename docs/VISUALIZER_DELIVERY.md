# Visualizer delivery

`SendspinClient.visualizerData` is a bounded `VisualizerDataStream`, not an unbounded
`AsyncStream`. Its mailbox counts each retained frame as the visualizer wire size:
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
