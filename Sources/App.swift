import AppKit
import Combine
import ServiceManagement

// RetroDrop's UI is a real NSMenu (with a custom view for the photo grid) rather than a
// floating panel: macOS keeps an auto-hidden menu bar visible while a menu is open, so it
// behaves like Apple's own menu bar items over full-screen apps.

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let controller = Controller.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem()
    private let errorLine = NSMenuItem()
    private let warningLine = NSMenuItem()
    private let noticeLine = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let safariItem = NSMenuItem()
    private let mailItem = NSMenuItem()
    private let folderItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let sendItem = NSMenuItem()
    private let preparingLine = NSMenuItem()
    private let waitingItem = NSMenuItem()
    private let photosView = PhotosMenuView()
    private var bag = Set<AnyCancellable>()

    private let stoppedIcon = AppDelegate.menuBarIcon("MenuBarStopped", fallback: "iphone")
    private let runningIcon = AppDelegate.menuBarIcon("MenuBarRunning", fallback: "iphone.radiowaves.left.and.right")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--print-ip") {  // diagnostics: the address phones should use
            print(Controller.lanIPv4() ?? "none")
            exit(0)
        }
        if args.contains("--register-login") { try? SMAppService.mainApp.register() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "RetroDrop"
        buildMenu()
        statusItem.menu = menu
        // Drop photos or videos onto the menu bar icon to send them to the phone.
        if let window = statusItem.button?.window {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }

        // @Published fires before the value changes, so refresh on the next pass of the
        // main queue (which also runs while the menu is open).
        controller.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &bag)
        refresh()

        if args.contains("--start") { controller.start() }
        // After an update, come back the way we were: server running if it was.
        Updater.shared.relaunchArguments = { [controller] in controller.isRunning ? ["--start"] : [] }
        if args.contains("--update-now") { Updater.shared.checkForUpdates(interactive: false) }  // scripting/tests
        // `--send file1 file2 ...` queues files for the phone (scripting and tests).
        if let i = args.firstIndex(of: "--send") {
            let files = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
            controller.send(Array(files))
        }
    }

    /// Finder's Open With → RetroDrop, or files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        controller.send(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private static func menuBarIcon(_ name: String, fallback: String) -> NSImage? {
        let image = NSImage(named: name)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "RetroDrop")
        image?.isTemplate = true  // follows light/dark menu bar automatically
        return image
    }

    // MARK: Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        for item in [statusLine, errorLine, warningLine, noticeLine] { item.isEnabled = false }
        toggleItem.target = self
        toggleItem.action = #selector(toggleServer)

        for item in [safariItem, mailItem] {
            item.target = self
            item.action = #selector(copyAddress(_:))
            item.toolTip = "Click to copy"
        }
        safariItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        mailItem.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)

        let howTo = item("How to Connect a Phone…", #selector(showHowTo))

        sendItem.title = "Send Photos & Videos to Phone…"
        sendItem.target = self
        sendItem.action = #selector(chooseFilesToSend)
        sendItem.image = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        sendItem.toolTip = "Or drop photos and videos onto the RetroDrop menu bar icon"
        preparingLine.isEnabled = false
        waitingItem.submenu = NSMenu()

        let photosItem = NSMenuItem()
        photosItem.view = photosView

        folderItem.target = self
        folderItem.action = #selector(openFolder)
        folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let changeFolder = item("Change Folder…", #selector(changeFolder))

        loginItem.title = "Open at Login"
        loginItem.target = self
        loginItem.action = #selector(toggleLogin)

        let about = item("About RetroDrop", #selector(showAbout))
        let updates = item("Check for Updates…", #selector(checkForUpdates))
        let quit = NSMenuItem(title: "Quit RetroDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        [statusLine, errorLine, warningLine, noticeLine, toggleItem, .separator(),
         .sectionHeader(title: "iOS 6 and later · open in Safari"), safariItem,
         .sectionHeader(title: "iOS 5 and earlier · mail server"), mailItem,
         howTo, .separator(),
         photosItem, .separator(),
         .sectionHeader(title: "Send to phone"), sendItem, preparingLine, waitingItem, .separator(),
         folderItem, changeFolder, loginItem, .separator(),
         about, updates, quit].forEach(menu.addItem)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refresh() {
        let running = controller.isRunning
        statusItem.button?.image = running ? runningIcon : stoppedIcon

        let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular)
                .applying(.init(paletteColors: [running ? .systemGreen : .tertiaryLabelColor])))
        statusLine.image = dot
        statusLine.attributedTitle = NSAttributedString(
            string: running ? "Running" : "Stopped",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        toggleItem.title = running ? "Stop Server" : "Start Server"

        setNote(errorLine, controller.error, color: .systemRed)
        setNote(warningLine, controller.mailWarning, color: .systemOrange)
        setNote(noticeLine, controller.portNotice, color: .systemBlue)

        safariItem.title = "http://\(controller.ip):\(controller.webPort)"
        mailItem.title = controller.ip
        // When running, grey out a route that couldn't start (the notes above say why).
        safariItem.isEnabled = !running || controller.webAvailable
        mailItem.isEnabled = !running || controller.mailAvailable

        folderItem.title = "Saving to “\(controller.folder.lastPathComponent)”"
        folderItem.toolTip = controller.folder.path
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshOutbox()
    }

    /// Multi-line note in the menu (menu items don't wrap on their own).
    private func setNote(_ item: NSMenuItem, _ text: String?, color: NSColor) {
        guard let text else { item.isHidden = true; return }
        item.isHidden = false
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count > 44, !line.isEmpty { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        lines.append(line)
        item.attributedTitle = NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.foregroundColor: color, .font: NSFont.menuFont(ofSize: 12)])
    }

    /// "Waiting on phone" submenu: each item can be removed; the phone picks them up in Safari or Mail.
    private func refreshOutbox() {
        let items = controller.outboxItems
        let preparing = controller.outboxPreparing
        preparingLine.isHidden = preparing == 0
        preparingLine.title = preparing == 1 ? "Preparing 1 file for the phone…" : "Preparing \(preparing) files for the phone…"

        waitingItem.isHidden = items.isEmpty
        waitingItem.title = "Waiting on Phone (\(items.count))"
        let sub = waitingItem.submenu!
        sub.removeAllItems()
        sub.addItem(.sectionHeader(title: "Pick these up in Safari or Mail on the phone"))
        for item in items.reversed() {
            var title = item.name
            if let d = item.duration { title += String(format: "  ▶ %d:%02d", Int(d.rounded()) / 60, Int(d.rounded()) % 60) }
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.image = NSImage(contentsOf: controller.outbox.dir.appendingPathComponent(item.thumb)).map { img in
                let size = NSSize(width: 32, height: 32 * img.size.height / max(img.size.width, 1))
                return NSImage(size: size, flipped: false) { r in img.draw(in: r); return true }
            }
            let actions = NSMenu()
            let remove = NSMenuItem(title: "Remove", action: #selector(removeFromOutbox(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = item.id
            actions.addItem(remove)
            row.submenu = actions
            sub.addItem(row)
        }
        sub.addItem(.separator())
        let clear = NSMenuItem(title: "Remove All", action: #selector(clearOutbox), keyEquivalent: "")
        clear.target = self
        sub.addItem(clear)
    }

    @objc private func chooseFilesToSend() { controller.chooseFilesToSend() }
    @objc private func removeFromOutbox(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller.outbox.remove(id) }
    }
    @objc private func clearOutbox() { controller.outbox.clear() }

    // Dropping files onto the menu bar icon
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        mediaURLs(sender).isEmpty ? [] : .copy
    }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = mediaURLs(sender)
        guard !urls.isEmpty else { return false }
        controller.send(urls)
        return true
    }
    private func mediaURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { MediaConverter.kind(of: $0) != nil }
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refreshIP()
        controller.reloadFolder()
        refresh()
        photosView.reload()
    }

    // MARK: Actions

    @objc private func toggleServer() {
        controller.isRunning ? controller.stop() : controller.start()
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.title, forType: .string)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(controller.folder)
    }

    @objc private func changeFolder() {
        controller.chooseFolder()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    @objc private func showHowTo() {
        let ip = controller.ip
        let alert = NSAlert()
        alert.messageText = "Connect a phone to RetroDrop"
        alert.informativeText = """
        \(controller.isRunning ? "" : "First choose Start Server in the RetroDrop menu.\n\n")\
        The phone must be on the same Wi-Fi as this Mac.

        iOS 6 AND LATER (Safari)
        1. Open Safari and go to http://\(ip):\(controller.webPort)
        2. Tap Choose File, pick photos or videos, tap Upload.

        iOS 5 AND EARLIER (Mail), one-time setup
        1. Settings > Mail, Contacts, Calendars > Add Account > Other > Add Mail Account.
        2. Name: RetroDrop. Address: retrodrop@mac.local. Password: anything.
        3. Choose POP. Incoming and Outgoing Host Name: \(ip). Incoming user name: retrodrop, password: anything. Leave the outgoing user name and password blank.
        4. Tap Save. If asked to set up without SSL, tap Yes.

        To send: in Photos, open a photo or video, tap Share > Email, send from retrodrop@mac.local to any address. Nothing leaves your network.

        SENDING FROM THIS MAC TO THE PHONE
        Choose Send Photos & Videos to Phone in the RetroDrop menu, or drop files onto the menu bar icon. RetroDrop converts them for old iPhones. Then on the phone:
        • Safari: open the address above. Under From your Mac, tap a photo, then touch and hold it and tap Save Image. (Safari can play videos but not save them.)
        • Mail: check mail in the RetroDrop account. Each photo or video arrives as an email. Touch and hold it to save it.

        If this Mac's address changes, update both Host Names in that account.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Address")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
        }
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Send photos and videos from old iPhones to your Mac over Wi-Fi.\nFree and open source.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
