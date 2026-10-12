// SPDX-License-Identifier: MPL-2.0
import AppKit

/// Chrome auxiliary windows have no SwiftUI scene. Keep navigation commands
/// owned by the application and resolve the real key window on every use.
@MainActor
final class NativeTabCommands: NSObject, NSMenuItemValidation {
    private var items: [NSMenuItem] = []
    private let locationItem: NSMenuItem
    private let quickNavigationItem: NSMenuItem
    private var installing = false

    override init() {
        locationItem = NSMenuItem(title: "Open location…", action: #selector(openLocation(_:)), keyEquivalent: "l")
        quickNavigationItem = NSMenuItem(title:"Quick navigation…",action:#selector(openQuickNavigation(_:)),keyEquivalent:"k")
        super.init()
        quickNavigationItem.identifier = NSUserInterfaceItemIdentifier("neutrino.quickNavigation")
        quickNavigationItem.keyEquivalentModifierMask = .command
        quickNavigationItem.target = self
        locationItem.identifier = NSUserInterfaceItemIdentifier("neutrino.location")
        locationItem.keyEquivalentModifierMask = .command
        locationItem.target = self
        let definitions: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("new", "New tab", "t", .command),
            ("reopen", "Reopen closed tab", "t", [.command, .shift]),
            ("close", "Close tab", "w", .command),
            ("previous", "Previous tab", "[", [.command, .shift]),
            ("next", "Next tab", "]", [.command, .shift])
        ]
        items = definitions.map { id, title, key, modifiers in
            let item = NSMenuItem(title: title, action: #selector(performTabCommand(_:)), keyEquivalent: key)
            item.identifier = NSUserInterfaceItemIdentifier("neutrino.tab." + id)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
    }

    func install(in mainMenu: NSMenu?) {
        guard let mainMenu, !installing else { return }
        installing = true
        defer { installing = false }
        // Declared shortcuts locate the standard groups independently of their
        // localized titles. Replace the disabled location anchor with owned dispatch.
        let menus = mainMenu.items.compactMap(\.submenu)
        if let file = menus.first(where: { shortcut("n", [.command, .shift], in: $0) != nil }),
           let newWindow = shortcut("n", [.command, .shift], in: file) {
            place(items[0], in: file, after: newWindow)
            place(items[1], in: file, after: items[0])
            if let closeWindow = shortcut("w", [.command, .shift], in: file) {
                place(items[2], in: file, before: closeWindow)
                // Neutrino assigns Command-W to the current tab. Remove only
                // Cocoa's competing window-close alias; keep Close All.
                for item in file.items where item.action == #selector(NSWindow.performClose(_:)) &&
                    item.keyEquivalent.lowercased() == "w" &&
                    item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command {
                    file.removeItem(item)
                }
            }
            file.autoenablesItems = true
        }
        if let browse = menus.first(where: { shortcut("l", .command, in: $0) != nil }),
           let switchPane = shortcut("`", [.command, .option], in: browse) {
            if let previousLocation = shortcut("l", .command, in: browse), previousLocation !== locationItem {
                place(locationItem, in: browse, before: previousLocation)
                browse.removeItem(previousLocation)
            }
            place(quickNavigationItem, in: browse, after: locationItem)
            place(items[4], in: browse, before: switchPane)
            place(items[3], in: browse, before: items[4])
            browse.autoenablesItems = true
        }
        // SwiftUI and Cocoa can both supply these standard Edit actions.
        // Preserve the first original responder item and its position.
        for edit in menus where edit.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
            for action in [NSSelectorFromString("startDictation:"), #selector(NSApplication.orderFrontCharacterPalette(_:))] {
                var found = false
                for item in edit.items where item.action == action {
                    if found { edit.removeItem(item) }
                    else { found = true }
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let app = AppDelegate.state, !app.finalQuitDataFrozen,
              !ChromiumRuntime.shared.finalQuitFrozen else { return false }
        if menuItem === locationItem || menuItem === quickNavigationItem {
            return ChromiumRuntime.shared.focusedNativeTab != nil || focusedBrowser?.app === app
        }
        guard let command = command(for: menuItem) else { return false }
        if let native = ChromiumRuntime.shared.focusedNativeTab, native.hasNativeNavigationChrome || native.isAuxiliary { return true }
        guard let browser = focusedBrowser, browser.app === app else { return false }
        if case .reopen = command { return browser.hasNativeTabs || !browser.closedTabs.isEmpty }
        return true
    }

    @objc private func performTabCommand(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let command = command(for: sender) else { return }
        if let tab = ChromiumRuntime.shared.focusedNativeTab, tab.performNativeTabCommand(command) { return }
        guard let browser = focusedBrowser else { return }
        if let action = browser.shellAction {
            switch command {
            case .new: action(["op":"newTab"])
            case .reopen: action(["op":"reopenTab"])
            case .close: action(["op":"closeTab","id":browser.session.selectedTabID.uuidString])
            case .previous, .next:
                let tabs = browser.session.tabs
                guard let index = tabs.firstIndex(where: { $0.id == browser.session.selectedTabID }), !tabs.isEmpty else { return }
                let next = (index + (command == .next ? 1 : tabs.count - 1)) % tabs.count
                action(["op":"selectTab","id":tabs[next].id.uuidString])
            }
        } else { browser.performTabCommand(command) }
    }

    @objc private func openQuickNavigation(_ sender:NSMenuItem) {
        guard sender===quickNavigationItem, validateMenuItem(sender) else { return }
        if let native=ChromiumRuntime.shared.focusedNativeTab { native.onBrowserCommand?("quickNavigation") }
        else { focusedBrowser?.shellAction?(["op":"palette"]) }
    }

    @objc private func openLocation(_ sender: NSMenuItem) {
        guard sender === locationItem, validateMenuItem(sender) else { return }
        if let tab = ChromiumRuntime.shared.focusedNativeTab, tab.focusAddressBar() { return }
        if let browser = focusedBrowser {
            NotificationCenter.default.post(name: .neutrinoFocusAddress, object: browser.session.id)
        }
    }

    private var focusedBrowser: BrowserModel? {
        var window = NSApp.keyWindow
        while let owner = window?.parent ?? window?.sheetParent { window = owner }
        guard let model = (window?.delegate as? WindowDelegateProxy)?.model, !model.isClosed,
              model.app.windows[model.session.id]?.model === model else { return nil }
        return model
    }

    private func command(for item: NSMenuItem) -> NativeTabCommand? {
        switch item.identifier?.rawValue {
        case "neutrino.tab.new": return .new
        case "neutrino.tab.reopen": return .reopen
        case "neutrino.tab.close": return .close
        case "neutrino.tab.previous": return .previous
        case "neutrino.tab.next": return .next
        default: return nil
        }
    }

    private func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first {
            $0.keyEquivalent.lowercased() == key &&
            $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers
        }
    }

    private func place(_ item: NSMenuItem, in menu: NSMenu, after anchor: NSMenuItem) {
        if item.menu === menu, menu.index(of: item) == menu.index(of: anchor) + 1 { return }
        item.menu?.removeItem(item)
        menu.insertItem(item, at: menu.index(of: anchor) + 1)
    }

    private func place(_ item: NSMenuItem, in menu: NSMenu, before anchor: NSMenuItem) {
        if item.menu === menu, menu.index(of: item) + 1 == menu.index(of: anchor) { return }
        item.menu?.removeItem(item)
        menu.insertItem(item, at: menu.index(of: anchor))
    }
}
