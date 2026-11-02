import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Two-key shortcuts only, by design.
enum Shortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, optionL, optionSlash

    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .optionL: return "⌥ L"
        case .optionSlash: return "⌥ /"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .optionSpace, .controlSpace: return UInt32(kVK_Space)
        case .optionL: return UInt32(kVK_ANSI_L)
        case .optionSlash: return UInt32(kVK_ANSI_Slash)
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .controlSpace: return UInt32(controlKey)
        default: return UInt32(optionKey)
        }
    }
}

enum Prefs {
    static let d = UserDefaults.standard

    static var shortcut: Shortcut {
        get { Shortcut(rawValue: d.string(forKey: "shortcut") ?? "") ?? .optionSpace }
        set { d.set(newValue.rawValue, forKey: "shortcut") }
    }
    static var theme: String {
        get { d.string(forKey: "theme") ?? Palette.all[0].id }
        set { d.set(newValue, forKey: "theme") }
    }
    static var model: String {
        get { d.string(forKey: "model")?.nonEmpty ?? Engine.defaultModel }
        set { d.set(newValue, forKey: "model") }
    }
    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }
}

// MARK: - Palettes

struct Swatch {
    var card: Color
    var ink: Color
    var soft: Color
    var faint: Color
    var accent: Color
    var mark: Color
    var markInk: Color
    var line: Color
    var codeBg: Color
}

struct Palette: Identifiable {
    let id: String
    let name: String
    let note: String
    let light: Swatch
    let dark: Swatch

    func swatch(_ scheme: ColorScheme) -> Swatch { scheme == .dark ? dark : light }

    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? all[0] }

    static let all: [Palette] = [
        // Tangent's manuscript paper and rubric red: the family resemblance.
        Palette(id: "rubric", name: "Rubric", note: "Warm paper, manuscript red. Tangent's sibling.",
                light: Swatch(card: Color(hex: 0xFBF7EF), ink: Color(hex: 0x26221C), soft: Color(hex: 0x5E5548),
                              faint: Color(hex: 0x9C917E), accent: Color(hex: 0xA8352A), mark: Color(hex: 0xF2D6CA),
                              markInk: Color(hex: 0x6E1E16), line: Color(hex: 0xE6DCCA), codeBg: Color(hex: 0xF1E9DA)),
                dark: Swatch(card: Color(hex: 0x1F1B17), ink: Color(hex: 0xEDE3D2), soft: Color(hex: 0xB5A992),
                             faint: Color(hex: 0x7A6F5F), accent: Color(hex: 0xE8876B), mark: Color(hex: 0x4A2820),
                             markInk: Color(hex: 0xFFD2C2), line: Color(hex: 0x3A332B), codeBg: Color(hex: 0x2B251F))),
        // Graphite with a highlighter: Look Up's yellow, done properly.
        Palette(id: "marker", name: "Marker", note: "Cool graphite, highlighter yellow.",
                light: Swatch(card: Color(hex: 0xFAFAF8), ink: Color(hex: 0x18181A), soft: Color(hex: 0x55555B),
                              faint: Color(hex: 0x98989F), accent: Color(hex: 0x8F6A00), mark: Color(hex: 0xFFE873),
                              markInk: Color(hex: 0x18181A), line: Color(hex: 0xE7E7E3), codeBg: Color(hex: 0xF0F0EC)),
                dark: Swatch(card: Color(hex: 0x19191B), ink: Color(hex: 0xF1F1EF), soft: Color(hex: 0xA9A9AE),
                             faint: Color(hex: 0x6C6C72), accent: Color(hex: 0xFFD84D), mark: Color(hex: 0x5C4D10),
                             markInk: Color(hex: 0xFFF1B0), line: Color(hex: 0x2E2E31), codeBg: Color(hex: 0x252528))),
        // Aubergine and coral, the Patch palette.
        Palette(id: "plum", name: "Plum & Coral", note: "Aubergine, coral. Patch's palette.",
                light: Swatch(card: Color(hex: 0xFBF6F8), ink: Color(hex: 0x2A1D2D), soft: Color(hex: 0x65536A),
                              faint: Color(hex: 0xA494A8), accent: Color(hex: 0xD8553F), mark: Color(hex: 0xFAD9CF),
                              markInk: Color(hex: 0x7A2414), line: Color(hex: 0xEADFE6), codeBg: Color(hex: 0xF3EAF0)),
                dark: Swatch(card: Color(hex: 0x221925), ink: Color(hex: 0xF3E9F1), soft: Color(hex: 0xBBA8BF),
                             faint: Color(hex: 0x7D6B81), accent: Color(hex: 0xFF8A70), mark: Color(hex: 0x55283A),
                             markInk: Color(hex: 0xFFD3C7), line: Color(hex: 0x3A2C3E), codeBg: Color(hex: 0x2E2232))),
    ]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, look, keys, permissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .look: return "Look"
        case .keys: return "Keys"
        case .permissions: return "Permissions"
        }
    }
}

/// Observable settings for SwiftUI.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    @Published var theme: String = Prefs.theme { didSet { Prefs.theme = theme } }
    @Published var shortcut: Shortcut = Prefs.shortcut { didSet { Prefs.shortcut = shortcut; onShortcutChange?() } }
    @Published var model: String = Prefs.model { didSet { Prefs.model = model } }
    @Published var shortcutFailed = false
    /// The Settings window's current pane, so the panel can open it at the right place.
    @Published var pane: SettingsPane = .general
    var onShortcutChange: (() -> Void)?
    var palette: Palette { Palette.named(theme) }
}
