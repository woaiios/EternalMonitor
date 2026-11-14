import Foundation
@preconcurrency import CoreVideo
import QuartzCore
import os

final class ControlChannelBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<ControlChannel?>(initialState: nil)
    var value: ControlChannel? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

final class StreamCounters: @unchecked Sendable {
    struct Snapshot {
        var datagrams = 0
        var datagramBytes = 0
        var assembled = 0
        var assembledBytes = 0
        var parsed = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    func recordDatagram(bytes: Int) {
        lock.withLock {
            $0.datagrams += 1
            $0.datagramBytes += bytes
        }
    }

    func recordAssembled(bytes: Int) {
        lock.withLock {
            $0.assembled += 1
            $0.assembledBytes += bytes
        }
    }

    func recordParsed() {
        lock.withLock { $0.parsed += 1 }
    }

    func drain() -> Snapshot {
        lock.withLock { current in
            let snapshot = current
            current = Snapshot()
            return snapshot
        }
    }
}

final class PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

final class FrameSlot: @unchecked Sendable {

    private struct Slot {
        var frame: PixelBufferBox?
        var newestSequence: UInt64 = 0
    }
    private let lock = os.OSAllocatedUnfairLock<Slot>(initialState: Slot())

    private struct CallbackHolder: @unchecked Sendable {
        var callback: (() -> Void)?
    }
    private let stored = os.OSAllocatedUnfairLock<CallbackHolder>(
        initialState: CallbackHolder()
    )

    var onFrameStored: (() -> Void)? {
        get { stored.withLock { $0.callback } }
        set { stored.withLock { $0.callback = newValue } }
    }

    @discardableResult
    func set(_ buffer: CVPixelBuffer, sequence: UInt64) -> Bool {
        let box = PixelBufferBox(buffer)
        let accepted = lock.withLock { slot in
            guard sequence >= slot.newestSequence else { return false }
            slot.newestSequence = sequence
            slot.frame = box
            return true
        }
        guard accepted else { return false }

        let callback = stored.withLock { $0.callback }
        callback?()
        return true
    }

    func take() -> CVPixelBuffer? {
        lock.withLock { slot in
            let wrapped = slot.frame
            slot.frame = nil
            return wrapped?.buffer
        }
    }
}

struct FPSCounter {
    private var timestamps: [CFTimeInterval] = []
    var currentFPS: Double = 0

    mutating func tick() {
        let now = CACurrentMediaTime()
        timestamps.append(now)
        timestamps.removeAll { now - $0 > 1.0 }
        currentFPS = Double(timestamps.count)
    }
}
