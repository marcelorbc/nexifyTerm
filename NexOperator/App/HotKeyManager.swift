import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onHotKey: (() -> Void)?

    var keyCode: UInt16 {
        get { UInt16(ConfigStore.shared.hotKeyCode) }
        set { ConfigStore.shared.hotKeyCode = Int(newValue) }
    }

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: UInt(ConfigStore.shared.hotKeyModifiers)) }
        set { ConfigStore.shared.hotKeyModifiers = Int(newValue.rawValue) }
    }

    var isEnabled: Bool {
        get { ConfigStore.shared.hotKeyEnabled }
        set {
            ConfigStore.shared.hotKeyEnabled = newValue
            if newValue { start() } else { stop() }
        }
    }

    func configure(onHotKey: @escaping () -> Void) {
        self.onHotKey = onHotKey
        if isEnabled { start() }
    }

    func start() {
        stop()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            NexLog.general.warning("Failed to create event tap – Accessibility permission required")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let flags = event.flags
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        let requiredMods = modifiers
        let currentMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))

        let relevantMask: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let match = currentMods.intersection(relevantMask) == requiredMods.intersection(relevantMask)

        if match && code == keyCode {
            DispatchQueue.main.async { [weak self] in
                self?.onHotKey?()
            }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    deinit {
        stop()
    }
}
