import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut via Carbon, which needs no permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x4153_4944), id: id) // 'ASID'
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &r)
        guard status == noErr, let r else { return nil }
        ref = r
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let h = HotKey.handlers[hk.id] { DispatchQueue.main.async { h() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
