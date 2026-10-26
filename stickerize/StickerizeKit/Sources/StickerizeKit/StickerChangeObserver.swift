import CoreFoundation
import Foundation

/// Cross-process change signal (Darwin notify center). Payload-free: receivers just reload the store.
/// The handler runs on the main thread. Observation stops when the object is deallocated.
public final class StickerChangeObserver: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<StickerChangeObserver>.fromOpaque(observer).takeUnretainedValue()
                if Thread.isMainThread {
                    me.handler()
                } else {
                    DispatchQueue.main.async { me.handler() }
                }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }

    static func post(name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
