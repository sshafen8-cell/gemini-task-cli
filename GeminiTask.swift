import AppKit
import ApplicationServices
import Darwin
import Foundation
import SQLite3

private let geminiBundle = "com.google.GeminiMacOS"
private let geminiPath = "/Applications/Gemini.app"
// Foreground events require an explicit per-invocation opt-in, never an omitted --worker.
private var interactiveUIAllowed = false

private func requireInteractiveUI() throws {
    guard interactiveUIAllowed else {
        throw BridgeError("interactive_required", "This operation can activate Gemini. Background mode did not send a foreground event. Use --interactive only when the user explicitly permits foreground interaction.")
    }
}

// Process ownership and UI coordination must not depend on a harness's archive path.
private let runtimeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("gemini-task/runtime", isDirectory: true)
private let sharedWorkerFile = runtimeDirectory.appendingPathComponent("worker-process.json")

struct WindowProbe {
    let error: AXError
    let windows: [AXUIElement]

    var responsive: Bool { error == .success }
    var mainWindowPresent: Bool? {
        guard responsive else { return nil }
        var uncertain = false
        for window in windows {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &raw)
            guard result == .success, let title = raw as? String, !title.isEmpty else {
                uncertain = true
                continue
            }
            if title.hasPrefix("Gemini - ") { return true }
        }
        return uncertain ? nil : false
    }
    var hasMainWindow: Bool { mainWindowPresent == true }

    static func read(_ pid: pid_t) -> WindowProbe {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.7)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        for window in windows { AXUIElementSetMessagingTimeout(window, 0.7) }
        return WindowProbe(error: error, windows: windows)
    }
}

private func requireResponsiveUI(_ pid: pid_t) throws -> WindowProbe {
    let probe = WindowProbe.read(pid)
    guard probe.responsive else {
        throw BridgeError("app_unresponsive", "Gemini did not answer its accessibility window query (AX \(probe.error.rawValue)). This operation stopped before changing the UI. Keep any existing job ID and do not resubmit it blindly. A CLI-owned idle process can be stopped with worker-stop without first hiding or opening its window.")
    }
    return probe
}

private func registeredWorker() -> WorkerProcess? {
    guard let data = try? Data(contentsOf: sharedWorkerFile) else { return nil }
    return try? JSONDecoder().decode(WorkerProcess.self, from: data)
}

struct AppAccount: Equatable {
    let slot: String
    let profileID: UUID

    var id: String { slot + "-" + profileID.uuidString.lowercased() }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(geminiBundle, isDirectory: true)
    }

    private static var profiles: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(geminiBundle, isDirectory: true)
            .appendingPathComponent("Gemini", isDirectory: true)
    }

    static func current() throws -> AppAccount {
        try read(selection: support.appendingPathComponent("account_config"), profiles: profiles)
    }

    static func read(selection: URL, profiles: URL) throws -> AppAccount {
        let unavailable = BridgeError("account_unconfirmed", "The active Gemini App account could not be identified. Wait for the account to finish loading.")
        guard let data = try? Data(contentsOf: selection), !data.isEmpty, data.count < 65_536,
              let slot = selectedSlot(in: Array(data)) else { throw unavailable }
        let database = profiles.appendingPathComponent(slot).appendingPathComponent("ChatInfo2.store")
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard opened == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT Z_UUID FROM Z_METADATA", -1, &statement, nil) == SQLITE_OK else {
            throw unavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
              let profile = UUID(uuidString: String(cString: value)), sqlite3_step(statement) == SQLITE_DONE else {
            throw unavailable
        }
        return AppAccount(slot: slot, profileID: profile)
    }

    private static func selectedSlot(in bytes: [UInt8]) -> String? {
        var cursor = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < bytes.count else { return nil }
                let byte = bytes[cursor]
                cursor += 1
                guard shift < 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }

        var active: String?
        while cursor < bytes.count {
            guard let tag = varint(), tag >> 3 != 0 else { return nil }
            // AccountManagerConfig.active_user_alias is protobuf field 4.
            if tag >> 3 == 4 && tag & 7 != 2 { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard length <= bytes.count - cursor else { return nil }
                cursor += length
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - cursor) else { return nil }
                let end = cursor + Int(length)
                if tag >> 3 == 4 {
                    guard active == nil, let name = String(bytes: bytes[cursor..<end], encoding: .utf8),
                          name.range(of: #"^user[0-9]{1,9}$"#, options: .regularExpression) != nil else { return nil }
                    active = name
                }
                cursor = end
            default: return nil
            }
        }
        return active
    }

    func requireCurrent() throws {
        guard try Self.current() == self else {
            throw BridgeError("account_changed", "Gemini changed accounts during this command. Retry under the active account.")
        }
    }

    func processUsesProfile(_ pid: pid_t) throws -> Bool {
        try requireCurrent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-b", "-w", "-n", "-P", "-p", String(pid), "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let prefix = Self.profiles.path + "/"
        let stores = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("n" + prefix), line.hasSuffix("/ChatInfo2.store") else { return nil }
            return String(line.dropFirst())
        })
        try requireCurrent()
        return stores == [prefix + slot + "/ChatInfo2.store"]
    }

    func requireProcess(_ pid: pid_t) throws {
        guard try processUsesProfile(pid) else {
            throw BridgeError("account_process_mismatch", "The Gemini process has not been verified under the active account. This operation stopped before accessing that conversation.")
        }
    }
}

struct BridgeError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

func poll<T>(_ seconds: TimeInterval = 8, _ check: () throws -> T?) throws -> T? {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if let value = try check() { return value }
        Thread.sleep(forTimeInterval: 0.14)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return nil
}

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

struct Node {
    let ref: AXUIElement
    var id: String { attr(ref, "AXIdentifier") as? String ?? "" }
    var role: String { attr(ref, "AXRole") as? String ?? "" }
    var title: String { attr(ref, "AXTitle") as? String ?? "" }
    var description: String { attr(ref, "AXDescription") as? String ?? "" }
    var help: String { attr(ref, "AXHelp") as? String ?? "" }
    var label: String { description.isEmpty ? title : description }
    var value: String { attr(ref, "AXValue") as? String ?? "" }
    var url: URL? {
        let raw = attr(ref, "AXURL")
        return (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
    }
    var selected: Bool { (attr(ref, "AXSelected") as? Bool) == true || (attr(ref, "AXValue") as? NSNumber)?.intValue == 1 }
    var enabled: Bool { attr(ref, "AXEnabled") as? Bool != false }
    var children: [Node] { (attr(ref, "AXChildren") as? [AXUIElement] ?? []).map(Node.init(ref:)) }
    var parent: Node? {
        guard let value = attr(ref, "AXParent"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Node(ref: value as! AXUIElement)
    }

    func descendants() -> [Node] {
        [self] + children.flatMap { $0.descendants() }
    }

    func isLabel(_ names: String...) -> Bool {
        names.contains { title == $0 || description == $0 }
    }

    func set(_ value: String) -> Bool {
        AXUIElementSetAttributeValue(ref, kAXValueAttribute as CFString, value as CFString) == .success
    }

    func press() throws {
        guard enabled else { throw BridgeError("control_disabled", "Gemini control is disabled: \(label)") }
        let error = AXUIElementPerformAction(ref, kAXPressAction as CFString)
        guard error == .success || error == .cannotComplete else {
            throw BridgeError("ui_action_failed", "Gemini did not accept the control action: \(id.isEmpty ? label : id) (\(error.rawValue))")
        }
    }
}

struct ClipboardCapture {
    let board = NSPasteboard.general
    let items: [NSPasteboardItem]

    init() {
        items = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    func restore(ifCount count: Int) {
        guard board.changeCount == count else { return }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}

struct WorkerProcess: Codable {
    let pid: pid_t
    let launchDate: Date
    var managed: Bool? = nil

    var application: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).first {
            $0.processIdentifier == pid && $0.launchDate == launchDate && !$0.isTerminated
        }
    }

    func requireBackground() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).count <= 1 else {
            throw BridgeError("multiple_app_instances", "More than one Gemini App process is running. Close the extra instances before using the single-app worker.")
        }
        guard let app = application else {
            throw BridgeError("worker_stopped", "The saved Gemini worker is no longer running.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else {
            throw BridgeError("worker_in_front", "Gemini is in the foreground. Switch away and retry; the CLI will not open another App.")
        }
        if !app.isHidden {
            // Only re-hide a process launched and registered by this CLI, never a user's main App.
            let owner = registeredWorker()
            guard owner?.pid == pid, owner?.launchDate == launchDate, owner?.managed == true else {
                throw BridgeError("worker_visible", "Gemini is visible and is not a verified CLI-managed worker. Its windows were left unchanged.")
            }
            _ = app.hide()
            guard try poll(3, {
                // AppKit refreshes NSRunningApplication properties on its run loop.
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
                return app.isHidden ? true : nil
            }) == true else {
                throw BridgeError("worker_hide_failed", "The CLI-managed Gemini worker did not become hidden. Retry after switching away from Gemini.")
            }
        }
    }
}

struct ActiveWorkerJob: Codable {
    let accountID: String
    let stateDirectory: String
    let jobID: String
}

struct Gemini {
    let running: NSRunningApplication
    let accessibility: AXUIElement
    let noNavigation: Bool
    let worker: WorkerProcess?
    let readOnly: Bool
    let observeAllWindows: Bool

    init(noNavigation: Bool = false, worker: WorkerProcess? = nil, readOnly: Bool = false,
         observationPID: pid_t? = nil) throws {
        self.noNavigation = noNavigation || worker != nil || readOnly
        self.worker = worker
        self.readOnly = readOnly
        observeAllWindows = observationPID != nil
        guard worker != nil || readOnly || interactiveUIAllowed else {
            throw BridgeError("interactive_required", "Background mode requires a verified CLI worker. The existing foreground App was left unchanged.")
        }
        guard AXIsProcessTrusted() else {
            throw BridgeError("accessibility_required", "Allow the command runner in macOS Privacy & Security > Accessibility, then retry.")
        }
        if let worker {
            guard let app = worker.application else {
                throw BridgeError("worker_stopped", "The saved independent Gemini worker is no longer running.")
            }
            _ = try requireResponsiveUI(worker.pid)
            try worker.requireBackground()
            running = app
            accessibility = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(accessibility, 1.8)
            return
        }
        if let observationPID {
            guard readOnly, let app = NSRunningApplication(processIdentifier: observationPID),
                  app.bundleIdentifier == geminiBundle, !app.isTerminated else {
                throw BridgeError("worker_stopped", "The verified Gemini process is no longer running.")
            }
            running = app
            accessibility = AXUIElementCreateApplication(observationPID)
            AXUIElementSetMessagingTimeout(accessibility, 0.7)
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).isEmpty {
            guard !self.noNavigation else {
                throw BridgeError("would_navigate", "Open the intended Gemini Task before using no-navigation mode.")
            }
            try Self.deliver("googlegemini://newchat")
        }
        guard let app = try poll(12, { NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).min {
            ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
        } }) else {
            throw BridgeError("app_unavailable", "The Gemini Mac app did not start.")
        }
        running = app
        if readOnly { _ = try requireResponsiveUI(app.processIdentifier) }
        accessibility = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(accessibility, 1.8)
    }

    static func deliver(_ argument: String) throws {
        try requireInteractiveUI()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", geminiBundle, argument]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError("open_event_failed", "macOS could not deliver the open event to Gemini.")
        }
    }

    var windows: [AXUIElement] {
        let front = attr(accessibility, "AXFocusedWindow").flatMap { value -> AXUIElement? in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let all = attr(accessibility, "AXWindows") as? [AXUIElement] ?? []
        let ordered = front.map { focused in [focused] + all.filter { !CFEqual($0, focused) } } ?? all
        return noNavigation && worker == nil && !observeAllWindows ? Array(ordered.prefix(1)) : ordered
    }

    func nodes(limit: Int = 580) -> [Node] {
        var ordered: [Node] = []
        var seen = Set<AXUIElement>()
        var roots = windows
        if let focus = attr(accessibility, "AXFocusedUIElement"), CFGetTypeID(focus) == AXUIElementGetTypeID() {
            var current = focus as! AXUIElement
            for _ in 0..<8 {
                let role = Node(ref: current).role
                if ["AXMenu", "AXPopover", "AXSheet", "AXDialog"].contains(role) { roots.insert(current, at: 0); break }
                guard let parent = attr(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = parent as! AXUIElement
            }
        }
        var stack = roots.reversed().map { ($0, 0) }
        while let (element, depth) = stack.popLast(), ordered.count < limit {
            guard depth <= 26, seen.insert(element).inserted else { continue }
            ordered.append(Node(ref: element))
            if let children = attr(element, "AXChildren") as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return ordered
    }

    func find(_ match: (Node) -> Bool) -> Node? {
        nodes().first(where: match)
    }

    func waitNode(_ description: String, _ seconds: TimeInterval = 8,
                  _ match: (Node) -> Bool) throws -> Node {
        if let node = try poll(seconds, { find(match) }) { return node }
        if let alert = approval() {
            throw BridgeError("needs_input", alert)
        }
        throw BridgeError("control_unavailable", "Gemini control not found: \(description)")
    }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) throws {
        try requireInteractiveUI()
        guard worker == nil else {
            throw BridgeError("worker_keyboard_unavailable", "The independent worker keeps its controls off the foreground keyboard.")
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            _ = running.activate(options: [])
            _ = AXUIElementSetAttributeValue(accessibility, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let window = windows.first {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw BridgeError("keyboard_unavailable", "macOS did not create the keyboard event.")
        }
        down.flags = flags
        up.flags = flags
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            down.postToPid(running.processIdentifier)
            up.postToPid(running.processIdentifier)
        }
    }

    func paste(_ text: String, into target: Node) throws {
        try requireInteractiveUI()
        _ = AXUIElementSetAttributeValue(target.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let clipboard = ClipboardCapture()
        clipboard.board.clearContents()
        clipboard.board.setString(text, forType: .string)
        let owned = clipboard.board.changeCount
        defer { clipboard.restore(ifCount: owned) }
        try key(9, .maskCommand)
        guard try poll(4, { target.value == text ? true : nil }) != nil else {
            throw BridgeError("prompt_not_entered", "Gemini did not expose the complete draft after paste.")
        }
    }

    func composer() -> Node? {
        find { $0.role == "AXTextArea" &&
            ($0.isLabel("分配任务", "Assign a task", "Assign task", "问问 Gemini", "Ask Gemini") ||
             $0.help.contains("输入给 Gemini 的提示") || $0.help.contains("prompt for Gemini")) }
    }

    var title: String {
        windows.compactMap { attr($0, "AXTitle") as? String }.first(where: { $0.hasPrefix("Gemini") }) ?? ""
    }

    func checkAvailable() throws {
        _ = try requireResponsiveUI(running.processIdentifier)
        if let alert = approval() { throw BridgeError("needs_input", alert) }
        if find({ $0.id == "stop_button" }) != nil {
            throw BridgeError("busy", "Gemini has a response running in the current window.")
        }
        let hasDraftText = composer().map { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        if hasDraftText || find({ $0.id == "send_button" && $0.enabled }) != nil {
            throw BridgeError("unsent_draft", "Gemini contains an unsent draft or attachment. Finish or clear it before opening another task.")
        }
    }

    func freshTask() throws {
        try requireInteractiveUI()
        try checkAvailable()
        try Self.deliver("googlegemini://newchat")
        try requireMainWindow()
        // A deep link can leave an existing Task selected; create a new composer explicitly.
        if find({ $0.id == "chat-input-mode-assign" }) == nil,
           let newChat = find({ $0.id == "newChat_button" || $0.role == "AXButton" && $0.isLabel("发起新对话", "New chat") }) {
            try newChat.press()
        }
        let toggle = try waitNode("Task mode toggle") { $0.id == "chat-input-mode-assign" }
        if !toggle.selected { try toggle.press() }
        _ = try waitNode("Task folder button") { $0.role == "AXButton" && $0.isLabel("文件夹", "Folders", "Folder") }
        try checkAvailable()
    }

    func prepareWorkerTask() throws {
        try worker?.requireBackground()
        try requireMainWindow()
        try checkAvailable()
        if find({ $0.id == "chat-input-mode-assign" }) == nil {
            try waitNode("new conversation in the worker") {
                $0.role == "AXButton" && ($0.id == "newChat_button" || $0.isLabel("发起新对话", "New chat"))
            }.press()
        }
        try worker?.requireBackground()
        let toggle = try waitNode("worker Task mode toggle") { $0.id == "chat-input-mode-assign" }
        if !toggle.selected { try toggle.press() }
        _ = try waitNode("worker Task folder control") {
            $0.role == "AXButton" && $0.isLabel("文件夹", "Folders", "Folder")
        }
        try worker?.requireBackground()
        if find({ $0.role == "AXButton" && $0.isLabel("移除", "Remove") &&
            ($0.help == "移除此选择" || $0.help == "Remove this selection") }) != nil {
            throw BridgeError("worker_draft_has_selection", "The worker has a retained selection. Restart the idle worker before submitting another task.")
        }
    }

    func requireMainWindow() throws {
        var lastState: Bool?
        guard try poll(5, {
            let probe = try requireResponsiveUI(running.processIdentifier)
            lastState = probe.mainWindowPresent
            return probe.hasMainWindow ? true : nil
        }) == true else {
            if lastState == nil {
                throw BridgeError("main_window_unconfirmed", "Gemini answered the window query but its main window could not be verified. No task was submitted or process restarted. Inspect doctor --ui; do not treat unknown window metadata as an idle App.")
            }
            throw BridgeError("main_window_unavailable", "Gemini is responsive but has no main conversation window. No prompt was submitted. For a CLI-owned idle instance use worker-stop and retry; do not expand a floating widget or add --interactive as a workaround.")
        }
    }

    func connectWorker(_ directory: URL) throws {
        try waitNode("worker connected folders menu") {
            $0.role == "AXButton" && $0.isLabel("文件夹", "Folders", "Folder")
        }.press()
        try worker?.requireBackground()
        guard let folder = try poll(6, {
            find { node in
                let path = (node.value as NSString).expandingTildeInPath
                return path.hasPrefix("/") &&
                    URL(fileURLWithPath: path).standardizedFileURL.path == directory.path
            }
        }) else {
            if let menu = find({ $0.role == "AXMenu" }) {
                _ = AXUIElementPerformAction(menu.ref, kAXCancelAction as CFString)
            }
            throw BridgeError("worker_folder_not_authorized", "The exact project directory is missing from the worker's authorized folders. Authorize it in Gemini before using the background worker.")
        }
        try folder.press()
        _ = try waitNode("worker connected folder chip") { $0.role == "AXButton" && $0.isLabel(directory.lastPathComponent) }
        try worker?.requireBackground()
    }

    func selectWorkerModel(_ name: String) throws -> String {
        guard let worker else { throw BridgeError("worker_missing", "A background worker is required.") }
        func selectedModel() -> String {
            let label = find { $0.id == "tab_stop_model_selector" }?.label ?? ""
            return (label.components(separatedBy: CharacterSet(charactersIn: "、，,")).first ?? label)
                .trimmingCharacters(in: .whitespaces)
        }
        let withoutVersion = name.replacingOccurrences(of: #"^\d+(?:\.\d+)?\s+"#, with: "", options: .regularExpression)
        var visited = Set<String>()
        var available: [String] = []
        for _ in 0..<10 {
            try worker.requireBackground()
            let selected = selectedModel()
            if selected.caseInsensitiveCompare(name) == .orderedSame ||
               selected.caseInsensitiveCompare(withoutVersion) == .orderedSame { return name }
            guard !selected.isEmpty, visited.insert(selected).inserted else { break }
            available.append(selected)
            // Gemini's native “Next model” shortcut is delivered only to this worker PID.
            for isKeyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 30, keyDown: isKeyDown) else {
                    throw BridgeError("worker_model_event_unavailable", "macOS could not create the worker model event.")
                }
                event.flags = [.maskCommand, .maskShift]
                event.postToPid(worker.pid)
            }
            guard try poll(3, {
                try worker.requireBackground()
                let next = selectedModel()
                return !next.isEmpty && next != selected ? true : nil
            }) != nil else { break }
        }
        throw BridgeError("worker_model_not_selected", "The worker could not select the requested model. Observed: " + available.joined(separator: ", "))
    }

    func approval() -> String? {
        let all = nodes(limit: 230)
        if let button = all.first(where: { $0.id == "action-button-1" }), button.enabled {
            let message = all.lazy.filter { $0.role == "AXStaticText" }.map {
                $0.value.isEmpty ? $0.label : $0.value
            }.first { $0.contains("允许") || $0.localizedCaseInsensitiveContains("allow") }
            return message ?? "Gemini is waiting for an in-app action."
        }
        return nil
    }

    func hasFolder(_ directory: URL) -> Bool {
        let name = directory.lastPathComponent
        return find { $0.role == "AXButton" && $0.isLabel(name) } != nil
    }

    func connect(_ directory: URL, allowNew: Bool) throws {
        try requireInteractiveUI()
        try Self.deliver(directory.path)
        guard let attached = try poll(12, {
            if let text = approval() {
                let confirm = find { $0.id == "action-button-1" && $0.isLabel("允许", "Allow", "添加文件夹", "Add folder", "Add Folder") }
                let sameFolder = text.contains(directory.lastPathComponent) &&
                    (text.contains("访问") || text.localizedCaseInsensitiveContains("access"))
                guard confirm != nil, sameFolder else { throw BridgeError("needs_input", text) }
                guard allowNew else {
                    throw BridgeError("folder_authorization_required", "Gemini is asking for access to this --cwd. Confirm it in Gemini, or dismiss it before retrying with --allow-new-folder.")
                }
                return false
            }
            return hasFolder(directory) ? true : nil
        }) else {
            throw BridgeError("folder_not_connected", "The open event did not connect the requested project directory.")
        }
        if !attached {
            let confirm = try waitNode("specific directory permission") {
                $0.id == "action-button-1" && $0.isLabel("允许", "Allow", "添加文件夹", "Add folder", "Add Folder")
            }
            guard let text = approval(), text.contains(directory.lastPathComponent),
                  text.contains("访问") || text.localizedCaseInsensitiveContains("access") else {
                throw BridgeError("needs_input", "The requested directory permission changed before confirmation.")
            }
            try confirm.press()
            _ = try waitNode("connected folder chip") { $0.role == "AXButton" && $0.isLabel(directory.lastPathComponent) }
        }
    }

    func modelMenu() throws -> [Node] {
        try requireInteractiveUI()
        let selector = try waitNode("model selector") { $0.id == "tab_stop_model_selector" }
        try selector.press()
        guard let choices = try poll(5, {
            let menu = find { $0.role == "AXPopover" || $0.role == "AXMenu" }
            guard let menu else { return nil as [Node]? }
            var stack = (attr(menu.ref, "AXChildren") as? [AXUIElement] ?? []).reversed().map { $0 }
            var matches: [Node] = []
            var counted = 0
            while let element = stack.popLast(), counted < 100 {
                counted += 1
                let node = Node(ref: element)
                if ["AXButton", "AXRadioButton", "AXMenuItem"].contains(node.role), node.enabled, !node.label.isEmpty {
                    matches.append(node)
                }
                stack.append(contentsOf: (attr(element, "AXChildren") as? [AXUIElement] ?? []).reversed())
            }
            return matches.isEmpty ? nil : matches
        }) else { throw BridgeError("models_unavailable", "The native model picker did not expose selectable models.") }
        return choices
    }

    func selectModel(_ name: String) throws -> String {
        let choices = try modelMenu()
        let matched = choices.filter {
            $0.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            $0.label.components(separatedBy: CharacterSet(charactersIn: "、，,")).contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
            }
        }
        guard matched.count == 1, let picked = matched.first else {
            try? key(53)
            throw BridgeError("model_not_found", "Use an exact displayed model name. Available: " + choices.map(\.label).joined(separator: " | "))
        }
        let expected = picked.label.components(separatedBy: CharacterSet(charactersIn: "、，,")).last?.trimmingCharacters(in: .whitespaces) ?? name
        try picked.press()
        let nameWithoutVersion = expected.replacingOccurrences(of: #"^\d+(?:\.\d+)?\s+"#, with: "", options: .regularExpression)
        _ = try waitNode("selected model reflected in composer", 5) { button in
            guard button.id == "tab_stop_model_selector" else { return false }
            let visibleName = button.label.components(separatedBy: CharacterSet(charactersIn: "、，,")).first ?? ""
            return visibleName.caseInsensitiveCompare(expected) == .orderedSame ||
                visibleName.caseInsensitiveCompare(nameWithoutVersion) == .orderedSame
        }
        return expected
    }

    func attach(_ file: URL) throws {
        try requireInteractiveUI()
        let name = file.lastPathComponent
        func attachmentCount() -> Int {
            nodes().filter {
                ($0.role == "AXImage" || $0.role == "AXStaticText") &&
                    ($0.help == name || $0.value == name || $0.isLabel(name))
            }.count
        }
        let before = attachmentCount()
        try Self.deliver(file.path)
        guard try poll(30, { attachmentCount() > before ? true : nil }) != nil else {
            if let alert = approval() { throw BridgeError("needs_input", alert) }
            throw BridgeError("attachment_not_verified", "Gemini did not expose a new attachment for \(name).")
        }
    }

    func fill(_ text: String) throws -> Node {
        guard !readOnly else { throw BridgeError("read_only", "This legacy job is being observed without changing the App.") }
        guard let draft = composer() else { throw BridgeError("composer_unavailable", "Gemini's task editor is unavailable.") }
        guard draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError("unsent_draft", "Gemini contains an unsent draft.")
        }
        if !draft.set(text) || draft.value != text {
            guard !noNavigation else {
                throw BridgeError("would_navigate", "Gemini did not accept direct draft entry. No-navigation mode skips the foreground keyboard fallback.")
            }
            try paste(text, into: draft)
        }
        _ = try waitNode("enabled Submit", 40) { $0.id == "send_button" && $0.enabled }
        return draft
    }

    func isPrompt(_ node: Node, marker: String) -> Bool {
        if node.role == "AXHeading" { return node.label.hasPrefix("[\(marker)]") }
        // Attached user messages use a button with a multiline description.
        return node.role == "AXButton" && node.label.hasPrefix("[\(marker)]\n")
    }

    func hasPrompt(_ marker: String) -> Bool {
        find { isPrompt($0, marker: marker) } != nil
    }

    func copyAnswerButton(_ marker: String) -> Node? {
        let all = nodes()
        guard let prompt = all.firstIndex(where: { isPrompt($0, marker: marker) }) else { return nil }
        return all[(prompt + 1)...]
            .prefix { !($0.label.hasPrefix("[GT-") && ($0.role == "AXHeading" || $0.role == "AXButton")) }
            .first { $0.id == "copy-button" }
    }

    func answer(_ marker: String) throws -> String {
        guard !readOnly else { throw BridgeError("read_only", "Read the saved answer with history-read instead of changing the App.") }
        guard let copy = copyAnswerButton(marker) else {
            throw BridgeError("answer_unavailable", "Gemini did not expose a Copy answer control for this delivered prompt.")
        }
        let clipboard = ClipboardCapture()
        let before = clipboard.board.changeCount
        try copy.press()
        guard let result = try poll(5, {
            let count = clipboard.board.changeCount
            guard count != before, let text = clipboard.board.string(forType: .string) else { return nil as (text: String, count: Int)? }
            return (text, count)
        }) else { throw BridgeError("answer_unavailable", "Gemini did not place an answer on the clipboard.") }
        clipboard.restore(ifCount: result.count)
        return result.text
    }

    func showsConversation(_ marker: String, nativeID: String?) -> Bool {
        title.contains(marker) || hasPrompt(marker) || (nativeID != nil && conversationID() == nativeID)
    }

    func selectConversation(_ marker: String, nativeID: String?) throws {
        if showsConversation(marker, nativeID: nativeID) { return }
        guard !noNavigation else {
            throw BridgeError("would_navigate", "The target Task is not the current Gemini conversation. No-navigation mode did not open it.")
        }
        if let id = nativeID {
            try Self.deliver("googlegemini://conversation/" + id)
        } else if let recent = find({ $0.role == "AXButton" && $0.label.contains(marker) }) {
            try recent.press()
        } else {
            throw BridgeError("conversation_not_visible", "The task is not visible in Gemini. Open its conversation by the job marker and retry.")
        }
        guard try poll(9, { title.contains(marker) || hasPrompt(marker) || (nativeID != nil && nativeID == conversationID()) ? true : nil }) != nil else {
            throw BridgeError("conversation_not_verified", "The expected task could not be verified after reopening.")
        }
    }

    func conversationID() -> String? {
        for node in nodes() where node.role == "AXLink" {
            guard let url = node.url, url.isFileURL else { continue }
            let path = url.pathComponents
            guard let p = path.lastIndex(of: "tasks"), p > 0, path[p - 1] == ".gemini", path.count > p + 2,
                  path[p + 2] == "backup" else { continue }
            if Self.isNativeID(path[p + 1]) { return path[p + 1] }
        }
        return nil
    }

    static func isNativeID(_ id: String) -> Bool {
        id.range(of: "^c_[0-9A-Fa-f]+$", options: .regularExpression) != nil
    }

    func progress() -> (state: String, label: String?) {
        let all = nodes()
        let progress = all.last(where: Self.isTaskProgressControl)
        if let answer = approval() { return ("needs_input", answer) }
        let label = progress?.label
        if let label, ["已停止", "已取消", "Stopped", "Cancelled", "Canceled"].contains(label) { return ("cancelled", label) }
        if let label, ["失败", "任务失败", "Failed", "Task failed"].contains(label) { return ("failed", label) }
        let completeLabels = ["已完成", "完成", "Completed", "Complete"]
        if all.contains(where: { $0.id == "stop_button" }) {
            return ("running", label.flatMap { completeLabels.contains($0) ? nil : $0 })
        }
        if let label, completeLabels.contains(label) { return ("completed", label) }
        return ("status_unconfirmed", label)
    }

    static func isTaskProgressControl(_ node: Node) -> Bool {
        let help = node.help
        return node.role == "AXButton" &&
            (help.contains("计划进度") || help.localizedCaseInsensitiveContains("plan progress") ||
             help.localizedCaseInsensitiveContains("task progress"))
    }

    func restoredDraft(_ marker: String) -> Bool {
        composer()?.value.hasPrefix("[\(marker)]\n") == true &&
            find({ $0.id == "stop_button" }) == nil
    }

    func stop() throws {
        guard !readOnly else { throw BridgeError("read_only", "Read-only observation cannot cancel a legacy foreground job.") }
        try waitNode("Stop task", 4) { $0.id == "stop_button" }.press()
    }
}

struct TranscriptMessage: Codable, Hashable {
    let role: String
    let text: String

    var response: [String: String] { ["role": role, "text": text] }
}

struct TranscriptSnapshot: Codable {
    private(set) var messages: [TranscriptMessage]
    let capturedAt: Date

    init?(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return nil }
        self.messages = messages
        capturedAt = Date()
    }

    func preserving(_ older: TranscriptSnapshot?) -> TranscriptSnapshot {
        guard let older else { return self }
        var merged = self
        let previousCounts = Dictionary(older.messages.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [TranscriptMessage: Int] = [:]
        merged.messages = older.messages + messages.filter { message in
            seen[message, default: 0] += 1
            return seen[message, default: 0] > previousCounts[message, default: 0]
        }
        return merged
    }
}

struct SavedPrompt: Codable {
    let marker: String
    let text: String
    let recordedAt: Date

    var response: [String: String] {
        ["marker": marker, "text": text, "recorded_at": ISO8601DateFormatter().string(from: recordedAt)]
    }
}

struct NativeTask: Codable {
    let id: String
    let localID: String?
    let title: String
    let query: String
    var lastSeen: Date? = nil
    var transcript: TranscriptSnapshot? = nil

    var response: [String: Any] {
        ["native_conversation_id": id, "local_task_id": localID as Any, "title": title]
    }
}

extension Gemini {
    private static let searchRowPrefix = "gemini_search_row_"

    func closeWorkerSearch() throws {
        if let close = find({ $0.id == "gemini_search_close_button" }) {
            try worker?.requireBackground()
            try close.press()
            guard try poll(4, { find { $0.id == "gemini_search_text_field" } == nil ? true : nil }) != nil else {
                throw BridgeError("history_search_still_open", "The worker did not close its Gemini history search.")
            }
        }
    }

    func workerSearch(_ query: String) throws -> [(String, Node)] {
        guard let worker else { throw BridgeError("worker_missing", "Gemini history commands require the hidden worker.") }
        try worker.requireBackground()
        try closeWorkerSearch()
        try checkAvailable()
        var searchField: Node?
        for _ in 0..<2 {
            try worker.requireBackground()
            if find({ $0.id == "gemini_search_text_field" }) == nil {
                try waitNode("worker history search") { $0.id == "sidebar_header_search" }.press()
            }
            searchField = try poll(5, {
                try worker.requireBackground()
                return find { $0.id == "gemini_search_text_field" }
            })
            if searchField != nil { break }
        }
        guard let field = searchField else {
            throw BridgeError("history_search_unavailable", "The hidden Gemini worker did not open native history search.")
        }
        if let clear = find({ $0.id == "gemini_search_clear_button" }) {
            try worker.requireBackground()
            try clear.press()
        } else if !field.value.isEmpty, !field.set("") {
            try? closeWorkerSearch()
            throw BridgeError("history_query_not_entered", "Gemini did not clear the previous search.")
        }
        // The reopened search can initially contain the previous query's rows.
        guard try poll(4, {
            try worker.requireBackground()
            return field.value.isEmpty && find { $0.id == "gemini_search_sort_button" } == nil ? true : nil
        }) != nil else {
            try? closeWorkerSearch()
            throw BridgeError("history_search_unconfirmed", "Gemini did not reset the previous search results.")
        }
        if query != field.value {
            guard field.set(query), field.value == query else {
                try? closeWorkerSearch()
                throw BridgeError("history_query_not_entered", "Gemini did not accept the history search query.")
            }
        }
        let results = try poll(9, {
            try worker.requireBackground()
            let all = nodes(limit: 2600)
            let rows: [(String, Node)] = all.compactMap { node in
                guard node.role == "AXButton", node.id.hasPrefix(Self.searchRowPrefix) else { return nil }
                let id = String(node.id.dropFirst(Self.searchRowPrefix.count))
                return Self.isNativeID(id) ? (id, node) : nil
            }
            let hasResults = !rows.isEmpty && (query.isEmpty || all.contains { $0.id == "gemini_search_sort_button" })
            if hasResults { return rows }
            if all.contains(where: { $0.id == "gemini_search_unavailable_view" }) { return [] }
            return nil
        })
        guard let results else {
            try? closeWorkerSearch()
            throw BridgeError("history_search_unconfirmed", "Gemini did not expose search results or an empty-results view.")
        }
        return results
    }

    func openWorkerResult(_ id: String, row: Node, query: String) throws -> NativeTask? {
        guard row.id == Self.searchRowPrefix + id else {
            throw BridgeError("native_task_unverified", "The Gemini search result changed before it could be opened.")
        }
        let resultLabel = row.label
        try worker?.requireBackground()
        try row.press()
        guard let name = try poll(9, { () throws -> String? in
            try worker?.requireBackground()
            guard find({ $0.id == "gemini_search_text_field" }) == nil, composer() != nil,
                  title.hasPrefix("Gemini - ") else { return nil }
            let name = String(title.dropFirst("Gemini - ".count))
            // A result contains the conversation title and may append a snippet and date.
            return !name.isEmpty && resultLabel.hasPrefix(name) ? name : nil
        }) else {
            throw BridgeError("native_task_unverified", "The worker could not confirm that the selected native search result opened.")
        }
        guard find(Self.isTaskProgressControl) != nil else { return nil }
        return NativeTask(id: id, localID: conversationID(), title: name, query: query.isEmpty ? name : query,
                          lastSeen: Date(), transcript: (try? loadedTranscript()).flatMap(TranscriptSnapshot.init))
    }

    func workerTask(_ id: String, query: String?, store: Store) throws -> NativeTask {
        guard Self.isNativeID(id) else { throw BridgeError("invalid_native_id", "Use a Gemini native ID beginning with c_.") }
        try store.requireAccount(self)
        let known = try store.nativeTask(id)
        if known == nil, let job = store.knownConversation(id) {
            return try reopenWorkerJob(job, query: query, store: store)
        }
        let nativeID = known?.id ?? id
        let search = query ?? known?.query ?? ""
        let results = try workerSearch(search)
        guard let row = results.first(where: { $0.0 == nativeID })?.1 else {
            try closeWorkerSearch()
            throw BridgeError("native_task_not_found", "The exact native ID is absent from this Gemini search. Discover it with tasks --query TEXT, or pass a known search term with --query.")
        }
        guard let opened = try openWorkerResult(nativeID, row: row, query: search) else {
            throw BridgeError("not_native_task", "The selected Gemini conversation did not expose a Task progress control.")
        }
        try store.requireAccount(self)
        return try store.remember(opened)
    }

    func reopenWorkerJob(_ job: Job, query: String? = nil, store: Store) throws -> NativeTask {
        try store.requireAccount(self)
        if let id = job.nativeConversationID ?? job.conversationID, let known = try store.nativeTask(id) {
            return try workerTask(known.id, query: query, store: store)
        }
        // The CLI puts a unique marker in each submitted prompt, including jobs from older builds.
        let marker = job.savedPrompts?.first?.marker ?? job.marker
        let search = query ?? marker
        let results = try workerSearch(search)
        let match = if let native = job.nativeConversationID {
            results.first { $0.0 == native }
        } else {
            results.count == 1 ? results.first : nil
        }
        guard let (id, row) = match else {
            try closeWorkerSearch()
            throw BridgeError("saved_task_not_found", "Gemini search did not uniquely locate the saved job.")
        }
        guard var task = try openWorkerResult(id, row: row, query: search),
              job.nativeConversationID == id || hasPrompt(marker) || hasPrompt(job.marker),
              job.conversationID == nil || task.localID == nil || job.conversationID == task.localID else {
            throw BridgeError("native_task_unverified", "The result did not match the identity of the saved job.")
        }
        if task.localID == nil, let local = job.conversationID {
            task = NativeTask(id: task.id, localID: local, title: task.title, query: task.query,
                              lastSeen: task.lastSeen, transcript: task.transcript)
        }
        try store.requireAccount(self)
        return try store.remember(task)
    }

    func verifyWorkerTask(_ task: NativeTask) throws {
        try worker?.requireBackground()
        guard title == "Gemini - " + task.title, find(Self.isTaskProgressControl) != nil,
              find({ $0.id == "gemini_search_text_field" }) == nil else {
            throw BridgeError("native_task_unverified", "Gemini no longer displays the native Task selected in the worker.")
        }
        if let expected = task.localID, let displayed = conversationID(), expected != displayed {
            throw BridgeError("native_task_unverified", "The local Task ID changed before submission.")
        }
    }

    func loadedTranscript() throws -> [TranscriptMessage] {
        // SwiftUI also exposes detached reply controls for offscreen rows.
        // Start from a reply that has a path back to the rendered transcript.
        let container = nodes(limit: 1800).lazy.filter { $0.id == "copy-button" }.compactMap { button -> Node? in
            var current = button.parent
            while let node = current {
                if node.children.contains(where: { $0.role == "AXRow" }) { return node }
                current = node.parent
            }
            return nil
        }.first
        guard let container else {
            throw BridgeError("transcript_unavailable", "Gemini did not expose the loaded message rows.")
        }
        let loadedRows = (attr(container.ref, "AXRows") as? [AXUIElement])?.map(Node.init(ref:)) ?? container.children
        return loadedRows.filter { $0.role == "AXRow" }.compactMap { row in
            let all = row.descendants()
            if let copy = all.first(where: { $0.id == "copy-button" }) {
                // The reply text shares a group with the toolbar. Expanded plan steps are nested separately.
                let reply = copy.parent?.parent?.children.filter { $0.role == "AXStaticText" } ?? []
                let body = (reply.isEmpty ? all.filter { $0.role == "AXStaticText" } : reply)
                    .map { $0.value.isEmpty ? $0.label : $0.value }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                return body.isEmpty ? nil : TranscriptMessage(role: "assistant", text: body)
            }
            guard let prompt = all.first(where: { $0.role == "AXHeading" && !$0.label.isEmpty }) else { return nil }
            return TranscriptMessage(role: "user", text: prompt.label)
        }
    }
}

struct Snapshot: Codable, Equatable {
    let size: UInt64
    let modified: TimeInterval
    let inode: UInt64

    init?(_ path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.modified = modified.timeIntervalSince1970
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct Artifact: Codable {
    let path: String
    let before: Snapshot?
    var updated: Bool {
        guard let after = Snapshot(path) else { return false }
        return before != after
    }
}

struct Job: Codable {
    let jobID: String
    var marker: String
    let cwd: String
    var conversationID: String?
    var model: String?
    var state: String
    var progress: String?
    var artifacts: [Artifact]
    var updatedAt: Date
    var worker: WorkerProcess? = nil
    var nativeConversationID: String? = nil
    var historyTitle: String? = nil
    var savedPrompts: [SavedPrompt]? = nil
    var transcript: TranscriptSnapshot? = nil

    var isTerminal: Bool {
        ["completed", "missing_output", "failed", "cancelled"].contains(state)
    }

    var archivedAnswer: String? {
        var matched = false
        var answer: String?
        for message in transcript?.messages ?? [] {
            if message.role == "user" {
                if message.text.hasPrefix("[\(marker)]") {
                    matched = true
                    answer = nil
                } else if matched {
                    break
                }
            } else if matched && message.role == "assistant" {
                answer = message.text
            }
        }
        return answer
    }

    var response: [String: Any] {
        [
            "job_id": jobID,
            "marker": marker,
            "conversation_id": conversationID as Any,
            "native_conversation_id": nativeConversationID as Any,
            "model": model as Any,
            "worker_pid": worker?.pid as Any,
            "cwd": cwd,
            "status": state,
            "progress": progress as Any,
            "artifacts": artifacts.map { ["path": $0.path, "updated": $0.updated] },
            "updated_at": ISO8601DateFormatter().string(from: updatedAt)
        ]
    }
}

struct HistoryRecord {
    var task: NativeTask?
    var jobs: [Job] = []

    var latestJob: Job? { jobs.max { $0.updatedAt < $1.updatedAt } }
    var nativeID: String? { task?.id ?? jobs.compactMap(\.nativeConversationID).first }
    var localID: String? { task?.localID ?? latestJob?.conversationID ?? jobs.compactMap(\.conversationID).first }
    var id: String { nativeID ?? jobs.min { $0.jobID < $1.jobID }?.jobID ?? "" }
    var title: String { task?.title ?? latestJob?.historyTitle ?? latestJob?.marker ?? id }
    var updatedAt: Date? { [task?.lastSeen, latestJob?.updatedAt].compactMap { $0 }.max() }
    var prompts: [SavedPrompt] { jobs.flatMap { $0.savedPrompts ?? [] }.sorted { $0.recordedAt < $1.recordedAt } }

    var transcript: TranscriptSnapshot? {
        (jobs.map(\.transcript) + [task?.transcript]).compactMap { $0 }
            .sorted { $0.capturedAt < $1.capturedAt }
            .reduce(nil as TranscriptSnapshot?) { $1.preserving($0) }
    }

    func matches(_ id: String) -> Bool {
        localID == id || jobs.contains { $0.jobID == id || $0.conversationID == id }
    }

    func matchesQuery(_ query: String) -> Bool {
        let jobValues = jobs.flatMap { [$0.jobID, $0.marker, $0.cwd, $0.historyTitle ?? ""] }
        let fields = [title, id, localID ?? "", task?.query ?? ""] + jobValues +
            prompts.map(\.text) + (transcript?.messages.map(\.text) ?? [])
        return fields.contains { $0.localizedStandardContains(query) }
    }

    var response: [String: Any] {
        let latest = latestJob
        let canResume = nativeID != nil || jobs.contains { $0.worker != nil && $0.isTerminal }
        return ["history_id": id, "title": title, "native_conversation_id": nativeID as Any,
                "local_task_id": localID as Any, "job_id": latest?.jobID as Any,
                "job_ids": jobs.map(\.jobID).sorted(), "cwd": latest?.cwd as Any,
                "model": latest?.model as Any, "last_job_status": latest?.state as Any,
                "has_saved_text": transcript != nil || !prompts.isEmpty,
                "can_attempt_worker_resume": canResume,
                "updated_at": updatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any]
    }
}

struct Store {
    let base: URL
    let root: URL
    let account: AppAccount

    init() throws {
        let defaultPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gemini-task", isDirectory: true).path
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GEMINI_TASK_STATE_DIR"] ?? defaultPath, isDirectory: true)
        guard let account = try poll(3, { try? AppAccount.current() }) else {
            throw BridgeError("account_unconfirmed", "The active Gemini App account could not be identified. Wait for account loading, then retry.")
        }
        try self.init(base: base, account: account)
    }

    init(base: URL, account: AppAccount) throws {
        self.base = base
        self.account = account
        root = base.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(account.id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func requireAccount(_ app: Gemini) throws {
        try account.requireProcess(app.running.processIdentifier)
    }

    func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(runtimeDirectory.appendingPathComponent("ui.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BridgeError("lock_failed", "Cannot open the local command lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw BridgeError("bridge_busy", "Another gemini-task command is using the shared Gemini worker. Retry the same operation shortly.")
        }
        defer { flock(fd, LOCK_UN) }
        try account.requireCurrent()
        return try work()
    }

    func file(_ id: String) throws -> URL {
        guard id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw BridgeError("invalid_job_id", "Invalid job identifier.")
        }
        return root.appendingPathComponent(id + ".json")
    }

    func load(_ id: String) throws -> Job {
        let url = try file(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BridgeError("job_not_found", "No local record for job \(id).")
        }
        return try JSONDecoder().decode(Job.self, from: Data(contentsOf: url))
    }

    var workerFile: URL { sharedWorkerFile }
    var activeJobFile: URL { runtimeDirectory.appendingPathComponent("active-job.json") }

    func savedWorker() throws -> WorkerProcess? {
        guard FileManager.default.fileExists(atPath: workerFile.path) else { return nil }
        return try JSONDecoder().decode(WorkerProcess.self, from: Data(contentsOf: workerFile))
    }

    func worker(reuseOrLaunch: Bool) throws -> WorkerProcess {
        guard AXIsProcessTrusted() else {
            throw BridgeError("accessibility_required", "Allow this command's terminal or harness in macOS Privacy & Security > Accessibility, then retry. No Gemini process was launched.")
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle)
        guard apps.count <= 1 else {
            throw BridgeError("multiple_app_instances", "More than one Gemini App process is running. Close the extra instances; the CLI will not create or close another App.")
        }
        if let saved = try savedWorker(), saved.application != nil {
            _ = try requireResponsiveUI(saved.pid)
            try saved.requireBackground()
            try account.requireProcess(saved.pid)
            return saved
        }
        // Migrate the old per-archive worker only when its exact process identity is still valid.
        let legacyFile = root.appendingPathComponent("worker-process.json")
        if let data = try? Data(contentsOf: legacyFile),
           var legacy = try? JSONDecoder().decode(WorkerProcess.self, from: data), legacy.application != nil {
            try account.requireProcess(legacy.pid)
            legacy.managed = true
            try saveWorker(legacy)
            try legacy.requireBackground()
            return legacy
        }
        guard reuseOrLaunch else { throw BridgeError("worker_stopped", "No shared Gemini worker is running.") }
        guard apps.isEmpty else {
            throw BridgeError("single_app_in_use", "Gemini is already running outside the shared CLI worker. Quit that App when convenient, then retry: the CLI will launch one hidden instance and reuse it across harnesses. No window was changed and no second process was opened.")
        }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        command.arguments = ["-g", "-j", "-a", geminiPath]
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw BridgeError("worker_launch_failed", "macOS could not launch the shared hidden Gemini App.")
        }
        guard let started = try poll(12, {
            let new = NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).filter { $0.launchDate != nil }
            guard new.count <= 1 else { throw BridgeError("worker_launch_ambiguous", "More than one new Gemini instance appeared.") }
            return new.first
        }), let launchDate = started.launchDate else {
            throw BridgeError("worker_launch_failed", "No new Gemini process appeared.")
        }
        let identity = WorkerProcess(pid: started.processIdentifier, launchDate: launchDate, managed: true)
        _ = try poll(6, { identity.application?.isHidden == true ? true : nil })
        // Retain ownership even if startup/profile loading fails, so a retry cannot open a duplicate.
        try saveWorker(identity)
        try identity.requireBackground()
        guard try poll(9, { try account.processUsesProfile(identity.pid) ? true : nil }) != nil else {
            throw BridgeError("account_process_mismatch", "The hidden Gemini worker did not load the active account.")
        }
        // A loaded account/hidden process can precede SwiftUI's first usable main window.
        // Give only this freshly launched process a bounded readiness grace period.
        guard try poll(12, {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            let probe = WindowProbe.read(identity.pid)
            return probe.responsive && probe.hasMainWindow ? true : nil
        }) == true else {
            _ = try requireResponsiveUI(identity.pid)
            throw BridgeError("main_window_unavailable", "The newly launched hidden Gemini App did not expose its main window. No prompt was submitted; the owned process record was retained for recovery.")
        }
        return identity
    }

    private func saveWorker(_ identity: WorkerProcess) throws {
        try JSONEncoder().encode(identity).write(to: workerFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workerFile.path)
    }

    private func activeWorkerJob() throws -> ActiveWorkerJob? {
        guard FileManager.default.fileExists(atPath: activeJobFile.path) else { return nil }
        return try JSONDecoder().decode(ActiveWorkerJob.self, from: Data(contentsOf: activeJobFile))
    }

    func stopWorker() throws -> pid_t {
        guard AXIsProcessTrusted() else {
            throw BridgeError("accessibility_required", "Allow the actual command runner in macOS Accessibility before stopping its managed worker.")
        }
        guard let identity = try savedWorker(), identity.managed == true,
              let running = identity.application else {
            throw BridgeError("worker_not_owned", "No running process matches the shared CLI worker's PID, launch time and ownership record.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != identity.pid else {
            throw BridgeError("worker_in_front", "Gemini is in use in the foreground; worker-stop left it unchanged.")
        }
        try account.requireProcess(identity.pid)
        let probe = WindowProbe.read(identity.pid)
        if let active = try activeWorkerJob() {
            guard active.accountID == account.id else {
                throw BridgeError("worker_account_busy", "An unfinished job under another account owns the shared worker.")
            }
            let owner = try Store(base: URL(fileURLWithPath: active.stateDirectory), account: account)
            var job = try owner.load(active.jobID)
            if !job.isTerminal, probe.responsive {
                let observed = try Gemini(readOnly: true, observationPID: identity.pid)
                if observed.showsConversation(job.marker, nativeID: job.conversationID) {
                    update(&job, app: observed)
                    try owner.save(job)
                }
            }
            guard job.isTerminal else {
                throw BridgeError("worker_busy", "Job \(active.jobID) is unfinished. worker-stop did not terminate it, including when its UI is unresponsive.")
            }
            if FileManager.default.fileExists(atPath: activeJobFile.path) {
                try FileManager.default.removeItem(at: activeJobFile)
            }
        }
        if probe.responsive {
            let observed = try Gemini(readOnly: true, observationPID: identity.pid)
            try observed.checkAvailable()
        }
        // Recovery deliberately does not call requireBackground() or hide().
        // Ask the App to quit normally; never force-terminate an unresponsive process.
        _ = running.terminate()
        guard try poll(8, {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return identity.application == nil ? true : nil
        }) == true else {
            throw BridgeError("worker_stop_failed", "The verified CLI worker with no registered unfinished job did not finish a normal quit request. It was not force-terminated. Close it when convenient, then retry; opening or hiding its window is not required by the CLI.")
        }
        try FileManager.default.removeItem(at: workerFile)
        return identity.pid
    }

    func requireIdleWorker(_ app: Gemini) throws {
        if let active = try activeWorkerJob() {
            guard active.accountID == account.id else {
                throw BridgeError("worker_account_busy", "The shared worker has an unfinished job under another account. Finish or reconcile it before submitting new work.")
            }
            let owner = try Store(base: URL(fileURLWithPath: active.stateDirectory, isDirectory: true), account: account)
            var job = try owner.load(active.jobID)
            if !job.isTerminal, app.showsConversation(job.marker, nativeID: job.conversationID) {
                update(&job, app: app)
                try owner.save(job)
            }
            guard job.isTerminal else {
                throw BridgeError("worker_busy", "The shared worker has unfinished job \(active.jobID). Use status/wait with GEMINI_TASK_STATE_DIR=\(active.stateDirectory) before submitting another task.")
            }
            if FileManager.default.fileExists(atPath: activeJobFile.path) { try FileManager.default.removeItem(at: activeJobFile) }
        }
        try app.checkAvailable()
    }

    func knownConversation(_ id: String) -> Job? {
        jobs().filter { $0.conversationID == id || $0.nativeConversationID == id }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func jobs(in directory: URL? = nil) -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory ?? root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.compactMap {
            try? JSONDecoder().decode(Job.self, from: Data(contentsOf: $0))
        }
    }

    func save(_ job: Job) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let active = job.worker == nil ? nil : try activeWorkerJob()
        let ownsActiveJob = active.map {
            $0.accountID == account.id && $0.stateDirectory == base.path && $0.jobID == job.jobID
        } ?? false
        if job.worker != nil, !job.isTerminal, active != nil, !ownsActiveJob {
            throw BridgeError("worker_busy", "Another job owns the shared worker. The new prompt was not submitted.")
        }
        let url = try file(job.jobID)
        try encoder.encode(job).write(to: url, options: .atomic)
        if job.worker != nil {
            if job.isTerminal {
                if ownsActiveJob {
                    try FileManager.default.removeItem(at: activeJobFile)
                }
            } else {
                let active = ActiveWorkerJob(accountID: account.id, stateDirectory: base.path, jobID: job.jobID)
                try encoder.encode(active).write(to: activeJobFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeJobFile.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private var nativeTaskFile: URL { root.appendingPathComponent("native-tasks-index.json") }

    func nativeTasks() throws -> [NativeTask] {
        try nativeTasks(at: nativeTaskFile)
    }

    private func nativeTasks(at file: URL) throws -> [NativeTask] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([NativeTask].self, from: Data(contentsOf: file))
    }

    func nativeTask(_ id: String) throws -> NativeTask? {
        let entries = try nativeTasks()
        if let exact = entries.first(where: { $0.id == id }) { return exact }
        let matches = entries.filter { $0.localID == id }
        guard matches.count <= 1 else {
            throw BridgeError("ambiguous_history_id", "Multiple native conversations share this backup ID. Use the native conversation ID.")
        }
        return matches.first
    }

    @discardableResult
    func remember(_ task: NativeTask) throws -> NativeTask {
        try account.requireCurrent()
        var entries = try nativeTasks()
        let legacy = try? nativeTasks(at: base.appendingPathComponent("native-tasks-index.json"))
            .first { entry in
                entry.id == task.id && (entry.localID == nil || task.localID == nil || entry.localID == task.localID)
            }
        let previous = entries.first { $0.id == task.id } ?? legacy
        if let before = previous?.localID, let after = task.localID, before != after {
            throw BridgeError("native_task_unverified", "The native search result and local Task ID no longer match.")
        }
        let updated = NativeTask(id: task.id, localID: task.localID ?? previous?.localID, title: task.title, query: task.query,
                                 lastSeen: task.lastSeen ?? previous?.lastSeen,
                                 transcript: task.transcript?.preserving(previous?.transcript) ?? previous?.transcript)
        entries.removeAll { $0.id == task.id }
        entries.append(updated)
        try JSONEncoder().encode(entries).write(to: nativeTaskFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nativeTaskFile.path)
        for job in jobs(in: base) {
            let backupMatches = task.localID != nil && job.conversationID == task.localID
            let nativeMatches = job.nativeConversationID == task.id &&
                (task.localID == nil || job.conversationID == nil || backupMatches)
            guard nativeMatches || (job.nativeConversationID == nil && backupMatches),
                  !FileManager.default.fileExists(atPath: try file(job.jobID).path) else { continue }
            var verified = job
            verified.nativeConversationID = task.id
            try save(verified)
        }
        return updated
    }

    func history() throws -> [HistoryRecord] {
        let imported = try nativeTasks()
        let savedJobs = jobs()
        var aliases: [String: Set<String>] = [:]
        var records: [String: HistoryRecord] = [:]
        for task in imported {
            records["native:" + task.id] = HistoryRecord(task: task)
            if let local = task.localID { aliases[local, default: []].insert(task.id) }
        }
        for job in savedJobs {
            if let local = job.conversationID, let native = job.nativeConversationID {
                aliases[local, default: []].insert(native)
            }
        }
        for job in savedJobs {
            let candidates = job.conversationID.flatMap { aliases[$0] }
            let native = job.nativeConversationID ?? (candidates?.count == 1 ? candidates?.first : nil)
            let key = native.map { "native:" + $0 } ?? job.conversationID.map { "backup:" + $0 } ?? "job:" + job.jobID
            records[key, default: HistoryRecord()].jobs.append(job)
        }
        return records.values.sorted {
            let lhs = $0.updatedAt ?? .distantPast
            let rhs = $1.updatedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}

struct Options {
    var arguments: [String: [String]] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ args: [String]) throws {
        let named = Set(["--cwd", "--prompt", "--prompt-file", "--model", "--attach", "--result", "--timeout", "--query", "--limit"])
        let booleans = Set(["--allow-new-folder", "--json", "--no-navigation", "--worker", "--interactive", "--ui"])
        var index = 0
        while index < args.count {
            let key = args[index]
            index += 1
            if booleans.contains(key) {
                flags.insert(key)
            } else if named.contains(key) {
                guard index < args.count else { throw BridgeError("usage", "Missing value after \(key).") }
                if !["--attach", "--result"].contains(key), arguments[key] != nil {
                    throw BridgeError("usage", "Specify \(key) once.")
                }
                arguments[key, default: []].append(args[index])
                index += 1
            } else if key.hasPrefix("-") {
                throw BridgeError("usage", "Unknown option \(key).")
            } else {
                positionals.append(key)
            }
        }
    }

    subscript(_ key: String) -> String? { arguments[key]?.first }

    func validate(keys: [String], flags allowedFlags: [String] = [], positions: Int = 0) throws {
        guard Set(arguments.keys).isSubset(of: Set(keys)),
              flags.isSubset(of: Set(allowedFlags + ["--json", "--no-navigation", "--worker", "--interactive"])),
              positionals.count == positions else {
            throw BridgeError("usage", "Unexpected options or arguments for this command. See gemini-task help.")
        }
    }

    func prompt() throws -> String {
        if self["--prompt"] != nil, self["--prompt-file"] != nil {
            throw BridgeError("usage", "Specify either --prompt or --prompt-file.")
        }
        var text = self["--prompt"] ?? ""
        if let file = self["--prompt-file"] {
            let raw = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: file))
            guard let decoded = String(data: raw, encoding: .utf8) else { throw BridgeError("usage", "Prompt input must be UTF-8.") }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError("usage", "Provide a nonempty --prompt or --prompt-file.")
        }
        return text
    }

    func timeout() throws -> TimeInterval {
        guard let value = self["--timeout"] else { return 300 }
        guard let seconds = Int(value), (1...86400).contains(seconds) else {
            throw BridgeError("usage", "--timeout takes a whole number of seconds (1–86400).")
        }
        return Double(seconds)
    }

    func directory() throws -> URL {
        guard let path = self["--cwd"], !path.isEmpty else { throw BridgeError("usage", "--cwd is required.") }
        let directory = localURL(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeError("directory_not_found", "Working directory does not exist: \(directory.path)")
        }
        guard directory.path != "/" else {
            throw BridgeError("usage", "Select a project directory below the filesystem root.")
        }
        return directory
    }

    func attachments(in directory: URL) throws -> [URL] {
        try (arguments["--attach"] ?? []).map { path in
            let file = localURL(path, relativeTo: directory)
            guard Snapshot(file.path) != nil else {
                throw BridgeError("attachment_not_found", "Attachment must be an existing regular file: \(file.path)")
            }
            return file
        }
    }

    func expected(in directory: URL) throws -> [Artifact] {
        try (arguments["--result"] ?? []).map { path in
            let resolved = localURL(path, relativeTo: directory)
            guard resolved.path.hasPrefix(directory.path + "/") else {
                throw BridgeError("result_outside_project", "Expected result must be within --cwd: \(path)")
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw BridgeError("usage", "Expected result must be a file: \(path)")
            }
            return Artifact(path: resolved.path, before: Snapshot(resolved.path))
        }
    }
}

func localURL(_ path: String, relativeTo directory: URL? = nil) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let base = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath()
}

func appendMarker(_ prompt: String, marker: String) -> String {
    "[\(marker)]\n\(prompt)"
}

func submit(_ job: inout Job, app: Gemini, store: Store, prompt: String, expectedContext: Job? = nil,
            expectedNativeTask: NativeTask? = nil) throws {
    try app.worker?.requireBackground()
    try store.requireAccount(app)
    let marked = appendMarker(prompt, marker: job.marker)
    _ = try app.fill(marked)
    try app.worker?.requireBackground()
    if let expectedContext,
       !app.showsConversation(expectedContext.marker, nativeID: expectedContext.conversationID) {
        throw BridgeError("would_navigate", "The target Task changed before submission.")
    }
    let button = try app.waitNode("Submit") { $0.id == "send_button" && $0.enabled }
    if let expectedNativeTask { try app.verifyWorkerTask(expectedNativeTask) }
    try store.requireAccount(app)
    job.state = "submission_unknown"
    job.updatedAt = Date()
    job.savedPrompts = (job.savedPrompts ?? []) + [SavedPrompt(marker: job.marker, text: prompt, recordedAt: job.updatedAt)]
    try store.save(job)

    try button.press()
    try app.worker?.requireBackground()
    let marker = job.marker
    let received = try poll(12, { app.hasPrompt(marker) || app.title.contains(marker) ? true : nil })
    try store.requireAccount(app)
    if received == true {
        job.state = "submitted"
        update(&job, app: app)
    }
    try store.save(job)
}

func newJob(_ options: Options, store: Store, useWorker: Bool = true) throws -> Job {
    if useWorker && options.arguments["--attach"] != nil {
        throw BridgeError("worker_attachments_unavailable", "This mode uses the authorized original directory. Attachments are unavailable in the isolated worker.")
    }
    let directory = try options.directory()
    let prompt = try options.prompt()
    let attachments = try options.attachments(in: directory)
    let artifacts = try options.expected(in: directory)
    return try store.locked {
        let worker = useWorker ? try store.worker(reuseOrLaunch: true) : nil
        let app = try Gemini(worker: worker)
        try store.requireAccount(app)
        try store.requireIdleWorker(app)
        let jobID = UUID().uuidString.lowercased()
        let marker = "GT-" + String(jobID.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        var job = Job(jobID: jobID, marker: marker, cwd: directory.path, state: "preparing", artifacts: artifacts, updatedAt: Date())
        job.worker = worker
        if useWorker {
            try app.prepareWorkerTask()
            try app.connectWorker(directory)
        } else {
            try app.freshTask()
            try app.connect(directory, allowNew: options.flags.contains("--allow-new-folder"))
        }
        if let name = options["--model"] {
            job.model = useWorker ? try app.selectWorkerModel(name) : try app.selectModel(name)
        } else {
            job.model = app.find { $0.id == "tab_stop_model_selector" }?.label
        }
        for file in attachments { try app.attach(file) }
        guard app.hasFolder(directory) else {
            throw BridgeError("folder_not_connected", "The project directory is no longer visible in the task composer.")
        }
        do {
            try submit(&job, app: app, store: store, prompt: prompt)
        } catch {
            if job.state != "submission_unknown" { throw error }
            job.progress = "Submit outcome is ambiguous. Inspect the existing job before resubmitting."
            try store.save(job)
        }
        return job
    }
}

func update(_ job: inout Job, app: Gemini) {
    let state = app.progress()
    if let native = app.conversationID() { job.conversationID = native }
    job.progress = state.label
    if job.state == "cancel_requested", app.restoredDraft(job.marker) {
        job.state = "cancelled"
        job.progress = "Gemini stopped and restored this job's prompt as an unsent draft."
    } else if state.state == "completed" {
        let hasArtifacts = !job.artifacts.isEmpty && job.artifacts.allSatisfy(\.updated)
        if hasArtifacts || app.copyAnswerButton(job.marker) != nil {
            job.state = job.artifacts.allSatisfy(\.updated) ? "completed" : "missing_output"
        }
    } else if state.state == "status_unconfirmed", ["submitting", "submission_unknown", "submitted", "cancel_requested"].contains(job.state) {
        // Preserve delivery evidence until the native work panel reports a state.
    } else if job.state == "cancel_requested", state.state == "running" {
        // Wait for a native terminal signal after pressing Stop.
    } else {
        job.state = state.state
    }
    job.updatedAt = Date()
    if app.title.hasPrefix("Gemini - "), app.hasPrompt(job.marker) {
        job.historyTitle = String(app.title.dropFirst("Gemini - ".count)).components(separatedBy: "\n").first
    }
    if ["completed", "missing_output"].contains(job.state),
       let snapshot = (try? app.loadedTranscript()).flatMap(TranscriptSnapshot.init) {
        job.transcript = snapshot.preserving(job.transcript)
    }
}

func status(_ id: String, store: Store, noNavigation: Bool = false, requireWorker: Bool = false) throws -> Job {
    try store.locked {
        var job = try store.load(id)
        guard !requireWorker || job.worker != nil else {
            throw BridgeError("not_worker_job", "This job was not dispatched to an isolated worker.")
        }
        if job.isTerminal {
            // Recover a crash between persisting the terminal job and releasing its shared slot.
            if job.worker != nil { try store.save(job) }
            let canRefreshID = job.conversationID == nil &&
                (job.worker != nil || interactiveUIAllowed) &&
                ["completed", "missing_output"].contains(job.state) &&
                AXIsProcessTrusted() &&
                !NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle).isEmpty
            if canRefreshID, let app = try? Gemini(noNavigation: noNavigation, worker: job.worker),
               (try? store.requireAccount(app)) != nil,
               app.showsConversation(job.marker, nativeID: job.conversationID),
               let nativeID = app.conversationID() {
                try store.requireAccount(app)
                job.conversationID = nativeID
                job.updatedAt = Date()
                try store.save(job)
            }
            return job
        }
        let app: Gemini
        if job.worker != nil {
            if job.worker?.application == nil {
                job.worker = try store.worker(reuseOrLaunch: !noNavigation)
            }
            app = try Gemini(noNavigation: true, worker: job.worker)
        } else if !interactiveUIAllowed {
            app = try Gemini(noNavigation: true, readOnly: true)
        } else if noNavigation {
            app = try Gemini(noNavigation: true)
        } else {
            app = try Gemini()
        }
        try store.requireAccount(app)
        if job.state == "cancel_requested", app.restoredDraft(job.marker) {
            update(&job, app: app)
            try store.requireAccount(app)
            try store.save(job)
            return job
        }
        if !app.showsConversation(job.marker, nativeID: job.conversationID) {
            if noNavigation || app.readOnly {
                job.progress = "The selected Task differs from this job; no-navigation mode left the window unchanged."
                return job
            }
            if app.approval() != nil {
                job.progress = "A Gemini dialog is open. This job's current state could not be verified."
                return job
            }
            if let draft = app.composer(), !draft.value.isEmpty { return job }
            if app.find({ $0.id == "stop_button" }) != nil { return job }
            do {
                if job.worker != nil {
                    try app.checkAvailable()
                    let task = try app.reopenWorkerJob(job, store: store)
                    job.nativeConversationID = task.id
                    job.conversationID = task.localID ?? job.conversationID
                } else {
                    try app.selectConversation(job.marker, nativeID: job.conversationID)
                }
            } catch let error as BridgeError where ["conversation_not_visible", "conversation_not_verified"].contains(error.code) {
                job.progress = error.message
                return job
            }
        }
        update(&job, app: app)
        try store.requireAccount(app)
        try store.save(job)
        return job
    }
}

func waitForJob(_ job: Job, timeout: TimeInterval, store: Store, noNavigation: Bool = false) throws -> Job {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var latest = job
    while !latest.isTerminal, latest.state != "needs_input" {
        do {
            latest = try status(job.jobID, store: store, noNavigation: noNavigation)
        } catch let error as BridgeError where error.code == "bridge_busy" {
            // Another invocation is making a short, serialized UI transition.
        }
        if latest.isTerminal || latest.state == "needs_input" { break }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            latest.progress = "Wait timed out. Reuse this job ID with status or wait."
            break
        }
        Thread.sleep(forTimeInterval: 0.9)
    }
    if ["completed", "missing_output"].contains(latest.state), latest.conversationID == nil {
        let grace = min(4, max(0, deadline - ProcessInfo.processInfo.systemUptime))
        _ = try poll(grace) {
            if let refreshed = try? status(job.jobID, store: store, noNavigation: noNavigation) {
                latest = refreshed
            }
            return latest.conversationID != nil ? true : nil
        }
    }
    return latest
}

func follow(_ id: String, _ options: Options, store: Store, noNavigation: Bool, requireWorker: Bool = false) throws -> Job {
    if noNavigation && options.arguments["--attach"] != nil {
        throw BridgeError("would_navigate", "Native attachment events can activate Gemini. Prepare attachments outside no-navigation mode.")
    }
    let prompt = try options.prompt()
    return try store.locked {
        var job = try store.load(id)
        guard !requireWorker || job.worker != nil else {
            throw BridgeError("not_worker_job", "This job was not dispatched to an isolated worker.")
        }
        if job.worker == nil && !interactiveUIAllowed {
            throw BridgeError("interactive_required", "This job was created in foreground mode. Background mode will not submit to it. Use a verified worker/native Task, or --interactive only with explicit user permission.")
        }
        if job.worker != nil && options.arguments["--attach"] != nil {
            throw BridgeError("worker_attachments_unavailable", "Attachments are unavailable in the isolated worker.")
        }
        guard job.isTerminal else { throw BridgeError("busy", "Wait for the existing job to finish before sending a follow-up.") }
        let directory = localURL(job.cwd)
        let expected = try options.expected(in: directory)
        let attachments = try options.attachments(in: directory)
        if job.worker != nil {
            job.worker = try store.worker(reuseOrLaunch: !noNavigation)
        }
        let app = try Gemini(noNavigation: noNavigation, worker: job.worker)
        try store.requireAccount(app)
        if job.worker != nil { try store.requireIdleWorker(app) } else { try app.checkAvailable() }
        var reopened: NativeTask?
        if job.worker != nil, !app.showsConversation(job.marker, nativeID: job.conversationID) {
            guard !noNavigation else {
                throw BridgeError("would_navigate", "The requested job is not the selected Task. No-navigation mode did not open it.")
            }
            let task = try app.reopenWorkerJob(job, store: store)
            guard app.hasFolder(directory) else {
                throw BridgeError("folder_not_connected", "The reopened Task did not expose its previously connected project folder.")
            }
            reopened = task
            job.nativeConversationID = task.id
            job.conversationID = task.localID ?? job.conversationID
        } else {
            try app.selectConversation(job.marker, nativeID: job.conversationID)
        }
        for file in attachments { try app.attach(file) }
        guard reopened != nil || app.showsConversation(job.marker, nativeID: job.conversationID) else {
            throw BridgeError("conversation_changed", "The attachment open event left the expected Gemini conversation.")
        }
        let context = reopened == nil && (noNavigation || job.worker != nil) ? job : nil
        job.marker = "GT-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        job.artifacts = expected
        job.progress = nil
        try submit(&job, app: app, store: store, prompt: prompt, expectedContext: context, expectedNativeTask: reopened)
        return job
    }
}

func followNativeTask(_ id: String, _ options: Options, store: Store) throws -> Job {
    let directory = try options.directory()
    let prompt = try options.prompt()
    let artifacts = try options.expected(in: directory)
    return try store.locked {
        let worker = try store.worker(reuseOrLaunch: true)
        let app = try Gemini(worker: worker)
        try store.requireIdleWorker(app)
        let task = try app.workerTask(id, query: options["--query"], store: store)
        try app.checkAvailable()
        try app.verifyWorkerTask(task)
        guard app.hasFolder(directory) else {
            throw BridgeError("folder_not_connected", "The existing native Task did not expose a connected folder with the supplied --cwd name.")
        }
        let jobID = UUID().uuidString.lowercased()
        let marker = "GT-" + String(jobID.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        let model = app.find { $0.id == "tab_stop_model_selector" }?.label
        var job = Job(jobID: jobID, marker: marker, cwd: directory.path, conversationID: task.localID,
                      model: model, state: "preparing", artifacts: artifacts, updatedAt: Date(),
                      worker: worker, nativeConversationID: task.id)
        do {
            try submit(&job, app: app, store: store, prompt: prompt, expectedNativeTask: task)
        } catch {
            if job.state != "submission_unknown" { throw error }
            job.progress = "Submit outcome is ambiguous. Inspect the existing job before resubmitting."
            try store.save(job)
        }
        return job
    }
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func finish(_ job: Job) -> Int32 {
    emit(job.response)
    if ["failed", "missing_output", "submission_unknown"].contains(job.state) { return 1 }
    if job.state == "needs_input" { return 2 }
    return 0
}

let usage = """
gemini-task — control the installed Gemini Mac app

  doctor [--ui]
  models --interactive
  start [--worker] --cwd DIR (--prompt TEXT | --prompt-file FILE|-) [--model NAME]
        [--attach FILE ...] [--result FILE ...] [--allow-new-folder]
  run   [start options] [--timeout SECONDS]
  status JOB_ID
  wait JOB_ID [--timeout SECONDS]
  history [--query TEXT] [--limit N]
  history-read HISTORY_ID
  tasks [--query TEXT]
  read c_ID [--query TEXT]
  open JOB_ID|c_ID
  open --worker c_ID [--query TEXT]
  answer JOB_ID
  follow-up JOB_ID (--prompt TEXT | --prompt-file FILE|-) [--attach FILE ...]
            [--result FILE ...]
  follow-up --worker c_ID --cwd DIR (--prompt TEXT | --prompt-file FILE|-)
            [--query TEXT] [--result FILE ...]
  cancel JOB_ID
  worker-stop

Commands emit JSON. Relative attachment/output paths are relative to --cwd.
App operations default to the shared hidden worker; --worker is an optional alias.
--interactive explicitly permits foreground interaction. It is required for the
native model menu, attachments, and first folder authorization. Do not add it
unless the user permits foreground interaction; it conflicts with --worker.
--no-navigation (or GEMINI_TASK_NO_NAVIGATION=1) permits read commands and
follow-up to the already-selected Task. It rejects commands that open another page.
Background mode shares one hidden, CLI-managed Gemini App across all harnesses,
including different archive directories.
It never launches a second instance or takes over an unregistered main App.
tasks and read always use the worker. tasks lists verified Tasks from the
current native search, and read returns the conversation text loaded by Gemini.
history searches the local archive. history-read reads saved text without
starting Gemini. Set GEMINI_TASK_STATE_DIR to choose the archive directory.
"""

func main() throws -> Int32 {
    guard let command = CommandLine.arguments.dropFirst().first,
          !["--help", "-h", "help"].contains(command) else { print(usage); return 0 }
    let options = try Options(Array(CommandLine.arguments.dropFirst(2)))
    let explicitWorker = options.flags.contains("--worker") ||
        ProcessInfo.processInfo.environment["GEMINI_TASK_BACKGROUND_WORKER"] == "1"
    interactiveUIAllowed = options.flags.contains("--interactive")
    if interactiveUIAllowed && (explicitWorker || options.flags.contains("--no-navigation") ||
        ProcessInfo.processInfo.environment["GEMINI_TASK_NO_NAVIGATION"] == "1") {
        throw BridgeError("usage", "--interactive conflicts with --worker, background-worker environment settings, and --no-navigation.")
    }
    let useWorker = !interactiveUIAllowed
    if interactiveUIAllowed && ["tasks", "read"].contains(command) {
        throw BridgeError("usage", "Native history commands use the background worker; omit --interactive.")
    }
    if useWorker && command == "models" {
        throw BridgeError("interactive_required", "Listing the native model menu can activate Gemini. No App was opened. Background tasks can use --model NAME; list the menu with --interactive only when foreground interaction is explicitly permitted.")
    }
    if useWorker && (options.arguments["--attach"] != nil || options.flags.contains("--allow-new-folder")) {
        throw BridgeError("interactive_required", "Native file upload and first folder authorization can activate Gemini. No App was opened and no prompt was submitted. Use an already-authorized original folder, or --interactive only with explicit user permission.")
    }
    let noNavigation = options.flags.contains("--no-navigation") ||
        ProcessInfo.processInfo.environment["GEMINI_TASK_NO_NAVIGATION"] == "1"
    if noNavigation && !["doctor", "status", "wait", "history", "history-read", "answer", "follow-up", "worker-stop"].contains(command) {
        throw BridgeError("would_navigate", "This command can change the Gemini page. No-navigation mode did not call Gemini.")
    }
    if noNavigation && command == "follow-up" && options.positionals.first.map(Gemini.isNativeID) == true {
        throw BridgeError("would_navigate", "Following a native ID can search and open another Task. Use an already-selected CLI job with no-navigation mode.")
    }
    if command == "doctor" {
        try options.validate(keys: [], flags: ["--ui"])
        let app = Bundle(path: geminiPath)
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: geminiBundle)
        let worker = registeredWorker().flatMap { $0.application == nil ? nil : $0 }
        var response: [String: Any] = [
            "app_installed": app != nil,
            "app_version": app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as Any,
            "accessibility_trusted": AXIsProcessTrusted(),
            "desktop_running": !instances.isEmpty,
            "app_process_count": instances.count,
            "worker_policy": "single_app",
            "default_mode": "background",
            "foreground_requires_flag": "--interactive",
            "binary_path": CommandLine.arguments[0],
            "worker_pid": worker?.pid as Any,
            "worker_hidden": worker?.application?.isHidden as Any,
            "shared_runtime_directory": runtimeDirectory.path,
            "ui_lock_scope": "macos_user",
            "account_id": (try? AppAccount.current())?.id as Any,
            "transport": "macos_accessibility_and_local_deeplink",
            "path_transport": "launchservices_open_event"
        ]
        if options.flags.contains("--ui"), let instance = worker?.application ?? instances.first {
            let probe = WindowProbe.read(instance.processIdentifier)
            response["ui"] = ["pid": instance.processIdentifier, "responsive": probe.responsive,
                              "ax_error": probe.error.rawValue, "window_count": probe.windows.count,
                              "main_window_present": probe.mainWindowPresent as Any,
                              "foreground": NSWorkspace.shared.frontmostApplication?.processIdentifier == instance.processIdentifier]
        }
        emit(response)
        return app == nil ? 1 : 0
    }

    let store = try Store()
    switch command {
    case "models":
        try options.validate(keys: [])
        let choices = try store.locked {
            let app = try Gemini()
            try store.requireAccount(app)
            try store.requireIdleWorker(app)
            try app.freshTask()
            let choices = try app.modelMenu().map { ["label": $0.label, "selected": $0.selected] as [String: Any] }
            try? app.key(53)
            return choices
        }
        emit(["models": choices])
        return 0
    case "start", "run":
        let common = ["--cwd", "--prompt", "--prompt-file", "--model", "--attach", "--result"]
        try options.validate(keys: common + (command == "run" ? ["--timeout"] : []), flags: ["--allow-new-folder"])
        let timeout = try options.timeout()
        var job = try newJob(options, store: store, useWorker: useWorker)
        if command == "run" { job = try waitForJob(job, timeout: timeout, store: store) }
        let result = finish(job)
        return command == "run" && !job.isTerminal && result == 0 ? 3 : result
    case "status", "wait":
        try options.validate(keys: command == "wait" ? ["--timeout"] : [], positions: 1)
        let id = options.positionals[0]
        let saved = try store.load(id)
        guard !explicitWorker || saved.worker != nil else {
            throw BridgeError("not_worker_job", "This job was not dispatched to an isolated worker.")
        }
        let job = command == "status" ? try status(id, store: store, noNavigation: noNavigation, requireWorker: explicitWorker) :
            try waitForJob(saved, timeout: options.timeout(), store: store, noNavigation: noNavigation)
        let result = finish(job)
        return command == "wait" && !job.isTerminal && result == 0 ? 3 : result
    case "history":
        try options.validate(keys: ["--query", "--limit"])
        let query = options["--query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let records = try store.history().filter { query.isEmpty || $0.matchesQuery(query) }
        let limit: Int
        if let value = options["--limit"] {
            guard let number = Int(value), number > 0 else {
                throw BridgeError("usage", "--limit takes a positive whole number.")
            }
            limit = number
        } else {
            limit = records.count
        }
        let listed = Array(records.prefix(limit))
        try store.account.requireCurrent()
        emit(["scope": "local_archive", "account_id": store.account.id, "complete_account_history": false, "count": listed.count,
              "total_matches": records.count, "tasks": listed.map(\.response)])
        return 0
    case "history-read":
        try options.validate(keys: [], positions: 1)
        let id = options.positionals[0]
        let records = try store.history()
        let matches = records.filter { $0.matches(id) }
        let exact = records.first { $0.id == id }
        guard exact != nil || matches.count <= 1 else {
            throw BridgeError("ambiguous_history_id", "Multiple archived conversations share this backup ID. Use the history ID.")
        }
        guard let record = exact ?? matches.first else {
            throw BridgeError("history_not_found", "This conversation is not in the local archive.")
        }
        var response = record.response
        response["scope"] = "local_archive"
        response["account_id"] = store.account.id
        response["messages"] = record.transcript?.messages.map(\.response) ?? []
        response["saved_prompts"] = record.prompts.map(\.response)
        try store.account.requireCurrent()
        emit(response)
        return 0
    case "tasks":
        try options.validate(keys: ["--query"])
        let query = options["--query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response = try store.locked { () throws -> [String: Any] in
            let worker = try store.worker(reuseOrLaunch: true)
            let app = try Gemini(worker: worker)
            try store.requireIdleWorker(app)
            var results = try app.workerSearch(query)
            var seen = Set<String>()
            let ids = results.map { $0.0 }.filter { seen.insert($0).inserted }
            var tasks = [[String: Any]]()
            var checked = 0
            for (index, id) in ids.enumerated() {
                try store.account.requireCurrent()
                if index > 0 {
                    if app.find({ $0.id == "stop_button" }) != nil { break }
                    results = try app.workerSearch(query)
                }
                guard let row = results.first(where: { $0.0 == id })?.1 else { continue }
                if let task = try app.openWorkerResult(id, row: row, query: query) {
                    try store.requireAccount(app)
                    tasks.append(try store.remember(task).response)
                }
                checked += 1
            }
            try app.closeWorkerSearch()
            return ["scope": query.isEmpty ? "gemini_recent_search" : "gemini_query_results",
                    "account_id": store.account.id,
                    "complete_account_history": false, "matched_conversations": ids.count,
                    "checked_conversations": checked, "tasks": tasks, "worker_pid": worker.pid]
        }
        emit(response)
        return 0
    case "read":
        try options.validate(keys: ["--query"], positions: 1)
        let response = try store.locked { () throws -> [String: Any] in
            let worker = try store.worker(reuseOrLaunch: true)
            let app = try Gemini(worker: worker)
            try store.requireIdleWorker(app)
            let task = try app.workerTask(options.positionals[0], query: options["--query"], store: store)
            var response = task.response
            response["messages"] = try app.loadedTranscript().map(\.response)
            response["transcript_scope"] = "loaded_app_messages"
            response["status"] = app.progress().state
            response["worker_pid"] = worker.pid
            response["account_id"] = store.account.id
            try store.requireAccount(app)
            return response
        }
        emit(response)
        return 0
    case "open":
        try options.validate(keys: useWorker ? ["--query"] : [], positions: 1)
        let id = options.positionals[0]
        if useWorker {
            let response = try store.locked { () throws -> [String: Any] in
                let saved = Gemini.isNativeID(id) ? nil : try store.load(id)
                if let saved, saved.worker == nil && saved.nativeConversationID == nil {
                    throw BridgeError("interactive_required", "This legacy foreground job has no verified native Task identity. Background open left the App unchanged.")
                }
                let worker = try store.worker(reuseOrLaunch: true)
                let app = try Gemini(worker: worker)
                try store.requireIdleWorker(app)
                let task = if let saved {
                    try app.reopenWorkerJob(saved, query: options["--query"], store: store)
                } else {
                    try app.workerTask(id, query: options["--query"], store: store)
                }
                var result = task.response
                result["opened"] = true
                result["worker_pid"] = worker.pid
                result["account_id"] = store.account.id
                return result
            }
            emit(response)
            return 0
        }
        let response = try store.locked { () throws -> [String: Any] in
            let app = try Gemini()
            try store.requireAccount(app)
            try store.requireIdleWorker(app)
            if Gemini.isNativeID(id) {
                if let known = store.knownConversation(id) {
                    try app.selectConversation(known.marker, nativeID: id)
                    return ["conversation_id": id, "opened": true]
                }
                try Gemini.deliver("googlegemini://conversation/" + id)
                guard try poll(7, { app.conversationID() == id ? true : nil }) != nil else {
                    throw BridgeError("open_unverified", "Gemini accepted the link but did not expose this native task ID in the current window.")
                }
                return ["conversation_id": id, "opened": true]
            }
            let job = try store.load(id)
            try app.selectConversation(job.marker, nativeID: job.conversationID)
            return ["job_id": id, "conversation_id": job.conversationID as Any, "opened": true]
        }
        emit(response)
        return 0
    case "answer":
        try options.validate(keys: [], positions: 1)
        let response = try store.locked { () throws -> [String: Any] in
            let job = try store.load(options.positionals[0])
            guard !explicitWorker || job.worker != nil else {
                throw BridgeError("not_worker_job", "This job was not dispatched to an isolated worker.")
            }
            guard ["completed", "missing_output"].contains(job.state) else {
                throw BridgeError("answer_not_ready", "Wait until the native task has finished.")
            }
            if !interactiveUIAllowed {
                guard let answer = job.archivedAnswer else {
                    throw BridgeError("answer_not_archived", "No saved answer is available. Use status to observe the selected job, or read the verified native Task in the background. No window was opened.")
                }
                return ["job_id": job.jobID, "conversation_id": job.conversationID as Any,
                        "answer": answer, "source": "local_archive"]
            }
            let app = try Gemini(noNavigation: noNavigation, worker: job.worker)
            try store.requireAccount(app)
            try app.checkAvailable()
            try app.selectConversation(job.marker, nativeID: job.conversationID)
            let answer = try app.answer(job.marker)
            try store.requireAccount(app)
            return ["job_id": job.jobID, "conversation_id": job.conversationID as Any, "answer": answer]
        }
        emit(response)
        return 0
    case "follow-up":
        if useWorker, options.positionals.count == 1, Gemini.isNativeID(options.positionals[0]) {
            try options.validate(keys: ["--prompt", "--prompt-file", "--result", "--cwd", "--query"], positions: 1)
            return try finish(followNativeTask(options.positionals[0], options, store: store))
        }
        try options.validate(keys: ["--prompt", "--prompt-file", "--attach", "--result"], positions: 1)
        return try finish(follow(options.positionals[0], options, store: store, noNavigation: noNavigation, requireWorker: explicitWorker))
    case "worker-stop":
        try options.validate(keys: [])
        let stopped = try store.locked { try store.stopWorker() }
        emit(["status": "worker_stopped", "worker_pid": stopped])
        return 0
    case "cancel":
        try options.validate(keys: [], positions: 1)
        let job = try store.locked {
            var job = try store.load(options.positionals[0])
            if job.isTerminal { return job }
            if job.worker == nil && !interactiveUIAllowed {
                throw BridgeError("interactive_required", "Background mode will not cancel or navigate a legacy foreground job. No App controls were pressed.")
            }
            let app = try Gemini(worker: job.worker)
            try store.requireAccount(app)
            if job.worker != nil, !app.showsConversation(job.marker, nativeID: job.conversationID) {
                try app.checkAvailable()
                let task = try app.reopenWorkerJob(job, store: store)
                job.nativeConversationID = task.id
                job.conversationID = task.localID ?? job.conversationID
            } else {
                try app.selectConversation(job.marker, nativeID: job.conversationID)
            }
            try app.stop()
            job.state = "cancel_requested"
            job.updatedAt = Date()
            try store.save(job)
            let marker = job.marker
            _ = try poll(4, { app.restoredDraft(marker) || app.progress().state == "cancelled" ? true : nil })
            update(&job, app: app)
            try store.requireAccount(app)
            try store.save(job)
            return job
        }
        return finish(job)
    default:
        throw BridgeError("usage", "Unknown command \(command). See gemini-task help.")
    }
}

do {
    exit(try main())
} catch let error as BridgeError {
    emit(["status": "error", "error": error.code, "message": error.message])
    exit(error.code == "needs_input" || error.code == "folder_authorization_required" ? 2 : 1)
} catch {
    emit(["status": "error", "error": "system_error", "message": error.localizedDescription])
    exit(1)
}
