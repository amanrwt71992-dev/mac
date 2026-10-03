#if canImport(AppKit)
import AppKit
import CoreKit
import EditorKit
import LayoutKit

// MARK: - AppDelegate

/// Builds the window, the scroll view and the menu by hand.
///
/// There is no nib, no storyboard and no `@main`/`NSApplicationDelegateAdaptor`
/// SwiftUI host. That is a deliberate choice rather than austerity: the app has to
/// own its first responder, its input context and its drawing, and every one of
/// those is something a nib or a SwiftUI `NSViewRepresentable` wants to manage for
/// us. Doing it in code means the responder chain is exactly what this file says
/// it is, and there is no serialised state to fall out of sync with it.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var controller: DocumentController?
    private var editorView: EditorView?
    private var statusField: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        openNewDocument()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Document windows

    /// Starts a fresh document in the window.
    ///
    /// v1 is single-window: "New" replaces the document rather than opening
    /// another window, and there is no save, so nothing can be lost silently.
    /// Multi-document windows arrive with file support — a "New" that throws away
    /// an unsaved document is only acceptable while documents cannot be saved.
    func openNewDocument() {
        let document = WelcomeDocument.make()
        let controller = DocumentController(
            document: document,
            authorName: NSFullUserName()
        )
        self.controller = controller

        let contentSize = NSSize(width: 1000, height: 780)

        let view = EditorView(
            frame: NSRect(origin: .zero, size: contentSize),
            controller: controller
        )

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.42, alpha: 1)
        scroll.borderType = .noBorder

        let statusHeight: CGFloat = 24
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))

        scroll.frame = NSRect(
            x: 0,
            y: statusHeight,
            width: contentSize.width,
            height: contentSize.height - statusHeight
        )
        scroll.autoresizingMask = [.width, .height]

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = NSColor.secondaryLabelColor
        status.frame = NSRect(x: 12, y: 5, width: contentSize.width - 24, height: 15)
        status.autoresizingMask = [.width]

        container.addSubview(scroll)
        container.addSubview(status)

        view.statusHandler = { [weak status] text in
            status?.stringValue = text
        }

        if let window = window {
            window.contentView = container
            window.title = Self.windowTitle
            view.documentDidChange()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        } else {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = Self.windowTitle
            window.contentView = container
            window.minSize = NSSize(width: 420, height: 320)
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.window = window
        }

        editorView = view
        statusField = status
        controller.view = view
        view.documentDidChange()
        NSApp.activate()
    }

    static let windowTitle = "Zenith Workspace — Untitled"

    // MARK: Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // Application menu. Required: without it there is no Quit, no Hide, and
        // ⌘Q does nothing.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Zenith Workspace", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Zenith Workspace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Zenith Workspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        // There is no reader yet. Leaving the item enabled would be a promise the
        // app cannot keep; disabling it says so in the interface instead.
        openItem.isEnabled = false
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(AppDelegate.saveDocument(_:)), keyEquivalent: "s")
        saveItem.isEnabled = false
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit. Target nil: commands travel the responder chain to the editor view.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: #selector(EditorView.zenithUndo(_:)), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: #selector(EditorView.zenithRedo(_:)), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(EditorView.zenithCut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(EditorView.zenithCopy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(EditorView.zenithPaste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(EditorView.zenithSelectAll(_:)), keyEquivalent: "a")

        // Format
        let formatItem = NSMenuItem()
        mainMenu.addItem(formatItem)
        let formatMenu = NSMenu(title: "Format")
        formatItem.submenu = formatMenu
        let boldItem = formatMenu.addItem(withTitle: "Bold", action: #selector(EditorView.zenithToggleBold(_:)), keyEquivalent: "b")
        boldItem.keyEquivalentModifierMask = [.command]
        let italicItem = formatMenu.addItem(withTitle: "Italic", action: #selector(EditorView.zenithToggleItalic(_:)), keyEquivalent: "i")
        italicItem.keyEquivalentModifierMask = [.command]

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let zoomInItem = viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorView.zenithZoomIn(_:)), keyEquivalent: "=")
        zoomInItem.keyEquivalentModifierMask = [.command]
        let zoomOutItem = viewMenu.addItem(withTitle: "Zoom Out", action: #selector(EditorView.zenithZoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        let actualItem = viewMenu.addItem(withTitle: "Actual Size", action: #selector(EditorView.zenithZoomToActualSize(_:)), keyEquivalent: "0")
        actualItem.keyEquivalentModifierMask = [.command]

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func newDocument(_ sender: Any?) {
        openNewDocument()
    }

    @objc func openDocument(_ sender: Any?) {}

    @objc func saveDocument(_ sender: Any?) {}
}

#endif
