import Foundation
import SwiftUI
import AppKit

// Linux-spec .skn palette: INI with [Skin] Format=1 and twelve #RRGGBB
// colors under [Colors]. Mirrors src/skin.c of the Linux port; invalid or
// incomplete files are rejected so callers fall back to the built-in theme.
struct SknColors {
    var window, control, text, selection, selectionText: UInt32
    var border, hotBorder, buttonTop, buttonBottom: UInt32
    var summary, summaryText, progress: UInt32
}

struct SknEntry: Identifiable {
    let name: String
    let palette: ThemePalette
    var id: String { name }
}

enum SknParser {
    static func parse(_ source: String) -> SknColors? {
        var format = ""
        var values: [String: UInt32] = [:]
        var section = ""

        for rawLine in source.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "skin":
                if key.lowercased() == "format" { format = value }
            case "colors":
                if let color = hexColor(value) { values[key.lowercased()] = color }
            default:
                break
            }
        }

        guard format == "1" else { return nil }
        let required = ["window", "control", "text", "selection", "selectiontext",
                        "border", "hotborder", "buttontop", "buttonbottom",
                        "summary", "summarytext", "progress"]
        guard required.allSatisfy({ values[$0] != nil }) else { return nil }
        return SknColors(
            window: values["window"]!,
            control: values["control"]!,
            text: values["text"]!,
            selection: values["selection"]!,
            selectionText: values["selectiontext"]!,
            border: values["border"]!,
            hotBorder: values["hotborder"]!,
            buttonTop: values["buttontop"]!,
            buttonBottom: values["buttonbottom"]!,
            summary: values["summary"]!,
            summaryText: values["summarytext"]!,
            progress: values["progress"]!)
    }

    static func load(from url: URL) -> SknColors? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(source)
    }

    // Spec mapping onto the macOS ThemePalette slots:
    //   Window -> background gradient, Control -> card fill,
    //   Border -> divider, Selection -> accent, HotBorder -> folder tint.
    static func palette(for colors: SknColors) -> ThemePalette {
        let win = Color(hex: colors.window)
        return ThemePalette(
            bgTop: win.lighten(by: 0.05),
            bgBottom: win,
            cardOpacityFill: Color(hex: colors.control).opacity(0.45),
            divider: Color(hex: colors.border).opacity(0.9),
            accent: Color(hex: colors.selection),
            folderColor: Color(hex: colors.hotBorder),
            colorScheme: luminance(colors.window) < 0.5 ? .dark : .light)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        0.2126 * Double((rgb >> 16) & 255) / 255
            + 0.7152 * Double((rgb >> 8) & 255) / 255
            + 0.0722 * Double(rgb & 255) / 255
    }

    private static func hexColor(_ value: String) -> UInt32? {
        guard value.count == 7, value.hasPrefix("#") else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }

    func lighten(by amount: Double) -> Color {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(red: min(1, Double(ns.redComponent) + amount),
                     green: min(1, Double(ns.greenComponent) + amount),
                     blue: min(1, Double(ns.blueComponent) + amount))
    }
}
