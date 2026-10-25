import Foundation
import Synchronization
import Testing

@testable import SideloadCore

/// Counts what the flow asks the (fake) task to do.
private final class FakeTask: Sendable {
    private struct State {
        var suspends = 0
        var resumes = 0
        var cancels = 0
        var suspended = false
        var doubleSuspend = false
        var resumeWhileRunning = false
    }

    private let state = Mutex(State())

    var controls: DownloadFlow.Controls {
        DownloadFlow.Controls(
            suspend: { [self] in
                state.withLock {
                    if $0.suspended { $0.doubleSuspend = true }
                    $0.suspended = true
                    $0.suspends += 1
                }
            },
            resume: { [self] in
                state.withLock {
                    if !$0.suspended { $0.resumeWhileRunning = true }
                    $0.suspended = false
                    $0.resumes += 1
                }
            },
            cancel: { [self] in state.withLock { $0.cancels += 1 } })
    }

    var suspends: Int { state.withLock { $0.suspends } }
    var resumes: Int { state.withLock { $0.resumes } }
    var cancels: Int { state.withLock { $0.cancels } }
    var suspended: Bool { state.withLock { $0.suspended } }
    var misused: Bool { state.withLock { $0.doubleSuspend || $0.resumeWhileRunning } }
}

@Suite("download flow control")
struct DownloadFlowTests {
    @Test("a lagging consumer suspends the task above the high mark and resumes it at the low mark, one for one")
    func suspendResume() {
        let task = FakeTask()
        let flow = DownloadFlow(maxBytes: 1 << 30, high: 4096, low: 1024)
        flow.attach(task.controls)
        var queue: [Int] = []
        for i in 0..<100 {
            #expect(flow.received(1000) { queue.append(1000) } == .accepted)
            // The consumer only gets to one block for every three that arrive.
            if i % 3 == 0, !queue.isEmpty { flow.consumed(queue.removeFirst()) }
            #expect(flow.maxPending <= 4096 + 1000, "bounded by the high mark plus one block")
            // While suspended the "server" delivers nothing; the consumer catches up.
            while task.suspended, !queue.isEmpty { flow.consumed(queue.removeFirst()) }
        }
        while !queue.isEmpty { flow.consumed(queue.removeFirst()) }
        #expect(task.suspends > 0 && task.suspends == task.resumes)
        #expect(!task.suspended && !flow.isSuspended)
        #expect(!task.misused, "never a second suspend, never a resume of a running task")
        #expect(task.cancels == 0)
    }

    @Test("a block past the cap is refused and cancels the task once, without being queued")
    func cap() {
        let task = FakeTask()
        let flow = DownloadFlow(maxBytes: 2500, high: 4096, low: 1024)
        flow.attach(task.controls)
        var queued = 0
        #expect(flow.received(1000) { queued += 1 } == .accepted)
        #expect(flow.received(1000) { queued += 1 } == .accepted)
        #expect(flow.received(501) { queued += 1 } == .exceeded)
        #expect(flow.received(1) { queued += 1 } == .exceeded)
        #expect(queued == 2 && task.cancels == 1)
        #expect(flow.maxPending == 2000)
    }

    @Test("after close nothing is suspended or resumed again, and a suspended task is left for cancel")
    func closeWhileSuspended() {
        let task = FakeTask()
        let flow = DownloadFlow(maxBytes: 1 << 30, high: 100, low: 10)
        flow.attach(task.controls)
        _ = flow.received(500) {}
        #expect(task.suspended && flow.isSuspended)
        flow.close()
        flow.consumed(500)
        #expect(task.resumes == 0, "no resume after the consumer is gone")
        _ = flow.received(500) {}
        #expect(task.suspends == 1)
    }

    @Test("a producer and a consumer on separate threads finish with no lost wakeup", .timeLimit(.minutes(1)))
    func noLostWakeup() async throws {
        let task = FakeTask()
        let flow = DownloadFlow(maxBytes: 1 << 40, high: 8192, low: 2048)
        flow.attach(task.controls)
        let queue = Mutex<[Int]>([])
        let blocks = 20_000
        let done = Mutex(false)

        let deadline = Date().addingTimeInterval(30)
        let producer = Thread {
            for _ in 0..<blocks {
                // A suspended task delivers nothing until it is resumed; a missed resume ends the loop at the
                // deadline instead of spinning forever.
                while task.suspended, Date() < deadline { Thread.sleep(forTimeInterval: 0.00002) }
                if Date() >= deadline { break }
                _ = flow.received(512) { queue.withLock { $0.append(512) } }
            }
            done.withLock { $0 = true }
        }
        var consumed = 0
        let finished = Date().addingTimeInterval(30)
        producer.start()
        while consumed < blocks, Date() < finished {
            if let next = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                flow.consumed(next)
                consumed += 1
            } else {
                try await Task.sleep(for: .microseconds(50))
            }
        }
        #expect(consumed == blocks, "the producer was left waiting for a resume")
        #expect(!task.suspended && task.suspends == task.resumes && !task.misused)
        #expect(flow.maxPending <= 8192 + 512)
    }
}

@Suite("download chunking")
struct DownloadChunkingTests {
    @Test("blocks are re-cut into 64 KiB pieces in order, whole blocks sliced and only a tail held back")
    func forwardPieces() throws {
        let piece = URLSessionTransport.downloadChunkBytes
        let source = Data((0..<(piece * 5 + 123)).map { UInt8($0 % 251) })
        let sizes = [10, piece + 5, 3 * piece, 1, 7_000, source.count]
        var blocks: [Data] = []
        var at = 0
        for size in sizes where at < source.count {
            let end = min(source.count, at + size)
            blocks.append(source[at..<end])
            at = end
        }
        let received = Mutex<[Data]>([])
        var buffer = Data()
        for block in blocks {
            try URLSessionTransport.forward(block, through: &buffer) { chunk in received.withLock { $0.append(Data(chunk)) } }
        }
        let pieces = received.withLock { $0 }
        #expect(pieces.allSatisfy { $0.count == piece })
        #expect(Data(pieces.joined()) + buffer == source)
        #expect(buffer.count < piece)
    }
}
