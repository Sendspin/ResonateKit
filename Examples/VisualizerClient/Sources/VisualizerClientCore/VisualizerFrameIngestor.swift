import SendspinKit

public enum VisualizerFrameIngestor {
    public static func consumeNext(
        from iterator: inout VisualizerFrameSubscription.Iterator
    ) async -> VisualizerFrame? {
        await iterator.next()
    }

    public static func consume(
        from subscription: VisualizerFrameSubscription,
        ingest: @escaping @Sendable (VisualizerFrame) async -> Void
    ) async {
        var iterator = subscription.makeAsyncIterator()
        while !Task.isCancelled, let frame = await consumeNext(from: &iterator) {
            await ingest(frame)
        }
    }
}
