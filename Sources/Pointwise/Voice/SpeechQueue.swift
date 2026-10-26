import Foundation

/// Plays spoken segments in order. Each segment's drawing commands run the
/// moment that segment starts, so Pointwise points while it talks about a thing.
/// Audio for the next sentences is made while the current one plays, so there
/// is no gap between sentences even with a network voice.
@MainActor
final class SpeechQueue {
    /// Runs the segment's commands and updates captions.
    var onSegmentStart: ((SpokenSegment) -> Void)?

    private struct QueuedSegment {
        let segment: SpokenSegment
        var preparation: Task<PreparedSpeech, Never>?
    }

    private let speechPlayer: SpeechPlayer
    private var pendingSegments: [QueuedSegment] = []
    private var workerTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many upcoming sentences to make audio for ahead of time.
    private static let prefetchDepth = 2

    init(speechPlayer: SpeechPlayer) {
        self.speechPlayer = speechPlayer
    }

    var isBusy: Bool { workerTask != nil }

    func enqueue(_ segments: [SpokenSegment]) {
        guard !segments.isEmpty else { return }
        pendingSegments.append(contentsOf: segments.map { QueuedSegment(segment: $0) })
        prepareUpcomingSpeech()
        startWorkerIfNeeded()
    }

    /// Stops speech now and drops everything queued.
    func stopAll() {
        for queuedSegment in pendingSegments { queuedSegment.preparation?.cancel() }
        pendingSegments.removeAll()
        workerTask?.cancel()
        workerTask = nil
        speechPlayer.stop()
        resumeIdleWaiters()
    }

    /// Returns once every queued segment has been spoken.
    func waitUntilIdle() async {
        guard isBusy else { return }
        await withCheckedContinuation { continuation in idleWaiters.append(continuation) }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    /// Starts making audio for the next few sentences that will be spoken aloud.
    private func prepareUpcomingSpeech() {
        guard shouldSpeakAloud else { return }
        var preparedCount = 0
        for segmentIndex in pendingSegments.indices where pendingSegments[segmentIndex].segment.hasSpeech {
            guard preparedCount < Self.prefetchDepth else { break }
            preparedCount += 1
            guard pendingSegments[segmentIndex].preparation == nil else { continue }
            let text = pendingSegments[segmentIndex].segment.text
            pendingSegments[segmentIndex].preparation = Task { [speechPlayer] in await speechPlayer.prepare(text) }
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled, !pendingSegments.isEmpty {
            var queuedSegment = pendingSegments.removeFirst()
            let segment = queuedSegment.segment
            if segment.hasSpeech && shouldSpeakAloud {
                if queuedSegment.preparation == nil {
                    let text = segment.text
                    queuedSegment.preparation = Task { [speechPlayer] in await speechPlayer.prepare(text) }
                }
                prepareUpcomingSpeech()
                // Wait for the audio before drawing, so the pointing and the words start together.
                guard let preparedSpeech = await queuedSegment.preparation?.value, !Task.isCancelled else { break }
                onSegmentStart?(segment)
                await speechPlayer.play(preparedSpeech)
            } else if segment.hasSpeech {
                // Muted: leave the caption up long enough to read it.
                onSegmentStart?(segment)
                let wordCount = segment.text.split(separator: " ").count
                try? await Task.sleep(nanoseconds: UInt64(max(1.2, Double(wordCount) / 3.2) * 1_000_000_000))
            } else {
                onSegmentStart?(segment)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard !Task.isCancelled else { return }
        workerTask = nil
        resumeIdleWaiters()
    }

    private var shouldSpeakAloud: Bool {
        return AppSettings.shared.speaksAloud && !SpeechPlayer.isSystemOutputMuted()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
