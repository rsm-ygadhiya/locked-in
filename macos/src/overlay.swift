// overlay.swift — the floating "End exam" button that sits over the lockdown.
//
// Before this, the only way out was to quit Chrome and wait for the passcode
// dialog to appear. That is fine when you know the trick and alarming when you
// don't: a student who needs to leave, or a proctor releasing one machine in a
// room of forty, should not have to attack the browser to be offered the door.
//
//   ./LockedInOverlay <verify-command> <release-file> <prompt-flag-file>
//
// It draws one small pill on top of everything, draggable anywhere on the screen
// and remembered there for next time. Click it and it asks for the code; the code
// goes to <verify-command> on stdin, exactly as the AppleScript prompt does, so
// an exam's own exit code and the machine's local passcode both work and neither
// is ever visible on this machine. On a correct code it touches <release-file>,
// which is what the lockdown watches for, and quits.
//
// Three details make it survive the lockdown it is drawn over:
//
//   * .accessory activation policy — no Dock icon, and System Events reports it
//     as background-only, so the lockdown's "quit and hide everything else" pass
//     leaves it alone.
//   * a non-activating panel at .screenSaver level that joins all Spaces —
//     Chrome is in a real fullscreen Space, and an ordinary window cannot draw
//     over one. This can, and clicking it does not take focus from Chrome.
//   * <prompt-flag-file> exists only while the code prompt is open, so the
//     lockdown's every-0.3s "put Chrome back in front" pass does not yank focus
//     out from under someone mid-keystroke.

import Cocoa

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(
        "usage: LockedInOverlay <verify-command> <release-file> <prompt-flag-file>\n"
            .data(using: .utf8)!)
    exit(64)
}
let verifyCommand = arguments[1]
let releaseFile = arguments[2]
let promptFlagFile = arguments[3]

// Where the pill was left last time. A proctor who moves it off the question they
// are watching should not have to move it again at the next exam.
let positionFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LockedIn/overlay-position.json")

func savedOrigin() -> NSPoint? {
    guard let data = try? Data(contentsOf: positionFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
          let x = object["x"], let y = object["y"] else { return nil }
    return NSPoint(x: x, y: y)
}

func saveOrigin(_ point: NSPoint) {
    let payload = ["x": Double(point.x), "y": Double(point.y)]
    try? FileManager.default.createDirectory(
        at: positionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
        try? data.write(to: positionFile)
    }
}

/// Borderless panels do not take key focus by default, and the code field needs it.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The pill. Drag it to move; click it — without dragging — to open the prompt.
final class PillView: NSView {
    var onClick: () -> Void = {}
    private var dragged = false

    override func draw(_ rect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.06, alpha: 0.95).setFill()
        body.fill()
        NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.45, alpha: 0.85).setStroke()
        body.lineWidth = 1.5
        body.stroke()
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged, let origin = window?.frame.origin { saveOrigin(origin) }
        if !dragged { onClick() }
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 168, height: 46),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
    let pill = PillView(frame: NSRect(x: 0, y: 0, width: 168, height: 46))
    let label = NSTextField(labelWithString: "🔒  End exam")
    let field = NSSecureTextField(frame: NSRect(x: 14, y: 12, width: 150, height: 24))
    let note = NSTextField(labelWithString: "")
    var prompting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        label.frame = NSRect(x: 0, y: 13, width: 168, height: 20)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.83, green: 1.0, blue: 0.89, alpha: 1)
        label.isSelectable = false
        pill.addSubview(label)
        pill.onClick = { [weak self] in self?.openPrompt() }
        panel.contentView = pill

        // Bottom-right by default: out of the way of a question, and where a
        // help button belongs on a screen nobody can leave.
        if let origin = savedOrigin() {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 200,
                                         y: screen.visibleFrame.minY + 40))
        }
        panel.orderFrontRegardless()
        // One line in overlay.log, because "the button did not appear" is otherwise
        // an unfalsifiable report: this says where it thinks it put itself.
        let where_ = panel.frame
        let screen = NSScreen.main?.visibleFrame ?? .zero
        FileHandle.standardError.write(
            "overlay: panel at \(where_) on screen \(screen)\n".data(using: .utf8)!)
    }

    // ---------- the code prompt ----------

    func openPrompt() {
        guard !prompting else { return }
        prompting = true
        FileManager.default.createFile(atPath: promptFlagFile, contents: nil)

        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y,
                              width: 260, height: 104), display: true)
        pill.frame = panel.contentView!.bounds
        label.frame = NSRect(x: 0, y: 74, width: 260, height: 20)
        label.stringValue = "Enter the exit code"

        field.frame = NSRect(x: 16, y: 42, width: 228, height: 24)
        field.stringValue = ""
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        field.placeholderString = "exit code or passcode"
        pill.addSubview(field)

        note.frame = NSRect(x: 16, y: 10, width: 228, height: 26)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.62, alpha: 1)
        note.stringValue = "Return to unlock · Esc to go back"
        note.alignment = .center
        pill.addSubview(note)

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        // Nobody should be able to leave this open as a way to browse freely while
        // the lockdown's focus enforcement is paused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if self?.prompting == true { self?.closePrompt() }
        }
    }

    func closePrompt() {
        prompting = false
        try? FileManager.default.removeItem(atPath: promptFlagFile)
        field.removeFromSuperview()
        note.removeFromSuperview()
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y,
                              width: 168, height: 46), display: true)
        pill.frame = panel.contentView!.bounds
        label.frame = NSRect(x: 0, y: 13, width: 168, height: 20)
        label.stringValue = "🔒  End exam"
        saveOrigin(panel.frame.origin)
    }

    @objc func submit() {
        let entry = field.stringValue
        guard !entry.isEmpty else { return }
        note.stringValue = "checking…"
        field.isEnabled = false
        // Off the main thread: the verifier asks the server, and a spinning beach
        // ball on top of a locked screen is its own small cruelty.
        DispatchQueue.global().async { [weak self] in
            let accepted = verify(entry: entry)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.field.isEnabled = true
                if accepted {
                    FileManager.default.createFile(atPath: releaseFile, contents: nil)
                    try? FileManager.default.removeItem(atPath: promptFlagFile)
                    self.label.stringValue = "Unlocking…"
                    self.note.stringValue = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                } else {
                    self.field.stringValue = ""
                    self.note.stringValue = "That code was not accepted."
                }
            }
        }
    }

    /// Esc backs out of the prompt. It arrives as an editing command on the field
    /// rather than as a key event on us, because the field is what has focus.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            closePrompt()
            return true
        }
        return false
    }
}

/// Pipe the code into the verifier on stdin — never as an argument, which every
/// other process on the machine could read. Exit 0 means it was accepted.
func verify(entry: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", verifyCommand]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    input.fileHandleForWriting.write(entry.data(using: .utf8) ?? Data())
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
