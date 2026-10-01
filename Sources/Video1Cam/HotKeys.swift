import Carbon

/// System-wide shortcuts via Carbon (no Accessibility permission needed).
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false

    static let signature: OSType = 0x5631_4341 // 'V1CA'

    /// Registers a shortcut (default ⌥⇧⌘ + key). Returns false if another app already owns it.
    @discardableResult
    static func register(id: UInt32, keyCode: Int, modifiers: Int = cmdKey | optionKey | shiftKey, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    static func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr, hk.signature == HotKeys.signature, let h = HotKeys.handlers[hk.id] {
                DispatchQueue.main.async { h() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
