// The launcher's themed layout, drawn when the app carries a background picture (dm/launcher_bg.jpg: the profile's launcher_bg.jpg, build_ipa.sh): the picture fills the screen, the game's
// icon sits in a white dream bubble with Play under it, the most used settings are bubbles at the sides (a menu or a switch each), and every setting is one tap away in a panel that slides
// up from the bottom (the settings list's rows, by section, and a Saves page with cloud saves, the memory and the reset). Play, the cloud save check and its questions stay in
// LauncherView (Launcher.swift), which shows this in place of its list. DM_LAUNCHER_THEME=0 in Documents/env.txt brings back the plain list
import SwiftUI
import UIKit

enum Dream {
    // The palette: Tomodachi Life's (pad_theme life) or Animal Crossing's (island: leaf greens for its yellow and orange, wood browns for its inks), from dm/launcher_theme (build_ipa.sh)
    static let island: Bool = {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher_theme"), let t = try? String(contentsOf: u, encoding: .utf8) else { return false }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) == "island"
    }()
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
    // island: Nook's Cranny, leaf green for the actions over the shop's oranges and creams, wood browns for the inks
    static let orange = island ? rgb(91, 181, 95) : Color(red: 1, green: 0.478, blue: 0.102)          // the main colour: Play, the selected tab, All settings
    static let orangeDark = island ? rgb(62, 143, 69) : Color(red: 0.91, green: 0.38, blue: 0.039)    // its shadow
    static let ink = island ? rgb(107, 74, 34) : Color(red: 0.353, green: 0.227, blue: 0.071)
    static let soft = island ? rgb(160, 123, 69) : Color(red: 0.604, green: 0.416, blue: 0.165)
    static let yellow = island ? rgb(123, 198, 126) : Color(red: 1, green: 0.831, blue: 0.231)       // the bubbles' icon discs
    static let rim = island ? rgb(246, 213, 142) : Color(red: 1, green: 0.878, blue: 0.541)
    static let iconInk = island ? rgb(90, 58, 18) : Color(red: 0.478, green: 0.243, blue: 0)
    static let cream = island ? rgb(255, 246, 218) : Color(red: 1, green: 0.973, blue: 0.902)
    static let shopOrange = rgb(255, 154, 31)   // the island panel's top edge
    static let dim = Color(red: 0.16, green: 0.24, blue: 0.35)
    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .rounded) }

    // SF Symbols for the settings the launcher lists (dm/games/settings.tsv); any other gets the sliders
    static func symbol(_ env: String) -> String {
        switch env {
        case "DM_OPMODE": return "gamecontroller"
        case "DM_LANG": return "character.bubble"
        case "DM_PICTURE_FIT": return "aspectratio"
        case "DM_ROTATION": return "rotate.right"
        case "DM_PRESENT_UPSCALE", "DM_RENDER_SCALE": return "sparkles"
        case "DM_SHOW_FPS": return "speedometer"
        case "DM_FPS_TARGET": return "gauge.with.dots.needle.67percent"
        case "DM_FRAMEGEN": return "waveform.path"
        case "DM_ULTRAWIDE": return "arrow.left.and.right"
        case "DM_TOUCH_HAPTICS": return "hand.tap"
        case "DM_RUMBLE": return "iphone.radiowaves.left.and.right"
        case "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN": return "dial.medium"
        case "DM_PAD_PRESS_TO_JOIN": return "person.badge.plus"
        case "DM_PRESENT_SNAP": return "square.stack.3d.up"
        case "DM_PSO_MTL4", "DM_PSO_PREBUILD": return "cpu"
        case "DM_NVN_ENC_THREAD": return "gearshape.2"
        case "DM_METAL_HUD": return "chart.bar.xaxis"
        default: return "slider.horizontal.3"
        }
    }
    static func sectionSymbol(_ section: String) -> String {
        switch section {
        case "Game": return "house"
        case "Controls": return "hand.point.up.left"
        case "Performance": return "bolt"
        case DreamLauncherView.savesTab: return "icloud"
        case DreamLauncherView.modsTab: return "puzzlepiece.extension"
        default: return "square.grid.2x2"
        }
    }
}

/// A rounded bubble: an icon in a disc, a value and a caption under it. accent: the orange one (All settings)
struct DreamChip: View {
    let symbol: String
    let value: String
    var caption: String? = nil
    var accent = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent ? Dream.orange : Dream.iconInk)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accent ? Color.white : Dream.yellow))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(Dream.font(13)).foregroundStyle(accent ? Color.white : Dream.ink)
                if let caption { Text(caption).font(Dream.font(10, .regular)).foregroundStyle(Dream.soft) }
            }
            .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
        .background(Capsule().fill(accent ? Dream.orange : Color.white.opacity(0.94)))
        .overlay(Capsule().strokeBorder(accent ? Color.white : Dream.rim, lineWidth: 3))
        .background(Capsule().fill(Dream.ink.opacity(0.15)).offset(y: 4))
        .contentShape(Capsule())
    }
}

/// Presses sink a little, as the game's own buttons do
struct DreamPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A NookPhone-style app tile (the Cranny layout): a coloured rounded square with a white symbol and rim, the value under it and the setting's name under that
struct CrannyTile: View {
    let symbol: String, value: String, caption: String, colour: Color
    var size: CGFloat = 54
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.31, style: .continuous).fill(colour))
                .overlay(RoundedRectangle(cornerRadius: size * 0.31, style: .continuous).strokeBorder(.white, lineWidth: 3))
                .background(RoundedRectangle(cornerRadius: size * 0.31, style: .continuous).fill(Dream.ink.opacity(0.18)).offset(y: 4))
            Text(value).font(Dream.font(12.5, .semibold)).foregroundStyle(Dream.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(caption).font(Dream.font(10, .regular)).foregroundStyle(Dream.soft).lineLimit(1)
        }
        .frame(width: size * 2.1)
        .contentShape(Rectangle())
    }
}

struct DreamLauncherView: View {
    static let savesTab = "Saves", modsTab = "Mods"
    @ObservedObject var m: LauncherModel
    @ObservedObject private var mods = ModStore.shared   // the Mods page and tile (Mods.swift)
    let background: UIImage
    let icon: UIImage?
    let version: String
    var title = ""   // the app's name (the Cranny layout's header)
    let memory: Int
    let checking: Bool
    let onPlay: () -> Void
    let onPlayWithoutCloud: () -> Void

    @State private var tab: String?   // the panel's page while it is open
    @State private var cloudOn = false
    @State private var modPicking: ModPicker.Kind?   // the Files picker of the Mods page
    @State private var modDeleting: ModStore.Mod?
    @State private var modEditing = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                if g.size.width < g.size.height { portrait(g.size) }
                else if Dream.island { cranny(g) }   // Animal Crossing: Nook's Cranny's own layout over its picture
                else { landscape(g.size) }
                if tab != nil { panel(g.size).zIndex(1) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background {
            Color.clear
                .overlay { Image(uiImage: background).resizable().scaledToFill() }
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .tint(Dream.orange)
        .onChange(of: tab) { _, t in if t == Self.modsTab { mods.reload(); mods.importDropped() } else { modEditing = false } }
        .sheet(item: $modPicking) { kind in
            ModPicker(kind: kind) { urls in modPicking = nil; mods.importItems(urls) } onCancel: { modPicking = nil; fputs("launcher: mods: picker cancelled\n", stderr) }
        }
        .confirmationDialog("Delete \(modDeleting?.id ?? "this mod")?", isPresented: Binding(get: { modDeleting != nil }, set: { if !$0 { modDeleting = nil } }), titleVisibility: .visible, presenting: modDeleting) { mod in
            Button("Delete mod", role: .destructive) { mods.delete(mod.id); modDeleting = nil }
            Button("Cancel", role: .cancel) { modDeleting = nil }
        } message: { _ in Text("Its files are removed from this iPhone. Your saves aren't touched.") }
        .environment(\.colorScheme, .light)   // its cream and white surfaces in any system appearance: preferredColorScheme alone left the panel's rows dark on a phone in dark mode
        .onAppear(perform: refreshCloud)
    }

    // ---------- Main screen ----------

    // Up to four settings for the sides, in this order when the game has them, then the first others the launcher lists; menus and switches only (a slider needs the panel)
    private var quick: [Setting] {
        let want = ["DM_FPS_TARGET", "DM_FRAMEGEN", "DM_ULTRAWIDE", "DM_OPMODE", "DM_LANG", "DM_RUMBLE"]
        // a menu with one choice left (Animal Crossing's frame rate, fixed at 30: Frame Generation is its 60) is not worth a tile
        let usable = m.settings.filter { ($0.kind == "toggle" || ($0.kind == "choice" && offeredOptions($0, current: m.values[$0.env]).count > 1)) && m.visible($0) }
        var picked = want.compactMap { k in usable.first { $0.env == k } }
        for s in usable where picked.count < 4 && !picked.contains(where: { $0.env == s.env }) { picked.append(s) }
        return Array(picked.prefix(4))
    }

    private func landscape(_ size: CGSize) -> some View {
        let q = quick, iconSize = min(112, size.height * 0.3)
        return ZStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    ForEach(Array(q.prefix(3).enumerated()), id: \.element.env) { i, s in
                        if i > 0 { Spacer(minLength: 8) }
                        quickChip(s)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing) {
                    if q.count > 3 { quickChip(q[3]); Spacer(minLength: 8) }
                    cloudChip
                    Spacer(minLength: 8)
                    allChip
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            centre(iconSize).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
        }
    }

    private func portrait(_ size: CGSize) -> some View {
        let q = quick
        return ScrollView {
            VStack(spacing: 22) {
                centre(min(128, size.width * 0.32)).padding(.top, 24)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                    ForEach(q, id: \.env) { quickChip($0) }
                    cloudChip
                    allChip
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // The icon in its bubble, Play, and the version and memory (or the cloud save check)
    private func centre(_ iconSize: CGFloat) -> some View {
        VStack(spacing: 12) {
            bubble(iconSize)
            Button(action: onPlay) {
                HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Play") }
                    .font(Dream.font(22, .semibold)).foregroundStyle(.white)
                    .frame(width: 190, height: 50)
                    .background(Capsule().fill(Dream.orange))
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 4))
                    .background(Capsule().fill(Dream.orangeDark).offset(y: 5))
            }
            .buttonStyle(DreamPress())
            .disabled(checking)
            .opacity(checking ? 0.7 : 1)
            Group {
                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the cloud save…")
                        Button("Play without it", action: onPlayWithoutCloud).foregroundStyle(Dream.orangeDark)
                    }
                } else {
                    Text("Version \(version) · \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)) free").monospacedDigit()
                }
            }
            .font(Dream.font(12)).foregroundStyle(Dream.ink)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.88)))
        }
    }

    private func bubble(_ iconSize: CGFloat) -> some View {
        Group {
            if let icon {
                Image(uiImage: icon).resizable().frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.23, style: .continuous))
            } else {
                Image(systemName: "gamecontroller.fill").font(.system(size: iconSize * 0.4)).foregroundStyle(Dream.orange).frame(width: iconSize, height: iconSize)
            }
        }
        .frame(width: iconSize + 44, height: iconSize + 28)
        .background(Ellipse().fill(.white))
        .overlay(alignment: .bottomTrailing) {   // the dream bubble's trail
            ZStack(alignment: .topLeading) {
                Circle().fill(.white).frame(width: 16, height: 16)
                Circle().fill(.white).frame(width: 9, height: 9).offset(x: 14, y: 14)
            }
            .offset(x: 10, y: -2)
        }
        .background(Ellipse().fill(Dream.ink.opacity(0.10)).offset(y: 6))
        .accessibilityHidden(true)
    }

    private func value(_ s: Setting) -> String {
        let v = m.values[s.env] ?? s.def
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == v }?[1] ?? v
        case "toggle": return v == s.onValue ? "On" : "Off"
        case "range": return m.rangeLabel(s, Double(v) ?? 0)
        default: return v
        }
    }

    @ViewBuilder private func quickChip(_ s: Setting) -> some View {
        let chip = DreamChip(symbol: Dream.symbol(s.env), value: value(s), caption: s.label)
        Group {
            if s.kind == "choice" {
                Menu {
                    Picker(s.label, selection: m.binding(s)) {
                        ForEach(offeredOptions(s, current: m.values[s.env]), id: \.[0]) { Text($0[1]).tag($0[0]) }
                    }
                } label: { chip }
            } else {
                Button { m.values[s.env] = (m.values[s.env] ?? s.def) == s.onValue ? s.offValue : s.onValue } label: { chip }
            }
        }
        .buttonStyle(DreamPress())
        .disabled(m.fixed.contains(s.env))
        .accessibilityLabel("\(s.label): \(value(s))")
    }

    private var cloudChip: some View {
        Button { open(Self.savesTab) } label: { DreamChip(symbol: cloudOn ? "icloud.fill" : "icloud", value: cloudOn ? "On" : "Off", caption: "Cloud saves") }
            .buttonStyle(DreamPress())
            .accessibilityLabel("Cloud saves: \(cloudOn ? "on" : "off")")
    }

    private var allChip: some View {
        Button { open(m.sections.first ?? Self.savesTab) } label: { DreamChip(symbol: "slider.horizontal.3", value: "All settings", accent: true) }
            .buttonStyle(DreamPress())
    }

    private func refreshCloud() {
        var stale: ObjCBool = false
        cloudOn = !(dm_cloud_saves_path(&stale) ?? "").isEmpty
    }

    // ---------- Nook's Cranny (pad_theme island, landscape) ----------
    // Laid out on its picture (the profile's launcher_bg.jpg: an orange band across the top 21 %, a cream middle, Timmy and Tommy's counter at the bottom right): the icon and name in
    // the band, the quick settings as NookPhone-style app tiles in the cream on the left, Play on the right above the counter. Positions are fractions of the whole screen (the picture
    // fills it, safe areas included), sizes follow its height
    private static let tileColour: [String: Color] = ["DM_FPS_TARGET": Dream.rgb(74, 144, 226), "DM_OPMODE": Dream.rgb(245, 155, 43), "DM_LANG": Dream.rgb(122, 111, 208),
                                                      "DM_RUMBLE": Dream.rgb(232, 116, 154), "DM_PICTURE_FIT": Dream.rgb(240, 120, 90), "DM_FRAMEGEN": Dream.rgb(122, 111, 208), "DM_ULTRAWIDE": Dream.rgb(240, 120, 90)]
    private func cranny(_ g: GeometryProxy) -> some View {
        let ins = g.safeAreaInsets, full = CGSize(width: g.size.width + ins.leading + ins.trailing, height: g.size.height + ins.top + ins.bottom)
        let k = min(max(full.height / 390, 0.8), 1.4), tile = 54 * k
        let y = { (f: CGFloat) in full.height * f - ins.top }, x = { (f: CGFloat) in full.width * f - ins.leading }   // whole-screen fractions → this view's coordinates
        let names = title.components(separatedBy: ": ")
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 12 * k) {   // the band: icon, name and version on the left, the free memory on the right
                if let icon { Image(uiImage: icon).resizable().frame(width: tile, height: tile).clipShape(RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous).strokeBorder(.white, lineWidth: 3)).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4 * k) {
                    Text(names.first ?? title).font(Dream.font(24 * k, .semibold)).foregroundStyle(.white).shadow(color: Dream.rgb(166, 90, 0).opacity(0.45), radius: 0, y: 2)
                    Text((names.count > 1 ? names[1...].joined(separator: ": ") + " · " : "") + "Version \(version)").font(Dream.font(12 * k)).foregroundStyle(.white)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)) free").monospacedDigit()
                    .font(Dream.font(12 * k)).foregroundStyle(Dream.ink).padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.92)))
            }
            .frame(width: g.size.width - 16).position(x: g.size.width / 2, y: y(0.105))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(116 * k), spacing: 8 * k), count: 3), alignment: .leading, spacing: 10 * k) {
                ForEach(quick.prefix(3), id: \.env) { s in crannyTile(s, tile) }   // three, then Mods: the grid holds six
                Button { open(Self.modsTab) } label: { CrannyTile(symbol: "puzzlepiece.extension", value: mods.enabledCount > 0 ? "\(mods.enabledCount) on" : "None on", caption: "Mods", colour: Dream.rgb(232, 116, 154), size: tile) }
                    .buttonStyle(DreamPress()).accessibilityLabel(mods.enabledCount > 0 ? "Mods, \(mods.enabledCount) on" : "Mods")
                Button { open(Self.savesTab) } label: { CrannyTile(symbol: cloudOn ? "icloud.fill" : "icloud", value: cloudOn ? "On" : "Off", caption: "Cloud saves", colour: Dream.rgb(59, 183, 176), size: tile) }
                    .buttonStyle(DreamPress()).accessibilityLabel("Cloud saves: \(cloudOn ? "on" : "off")")
                Button { open(m.sections.first ?? Self.savesTab) } label: { CrannyTile(symbol: "slider.horizontal.3", value: "All settings", caption: " ", colour: Dream.orange, size: tile) }
                    .buttonStyle(DreamPress())
            }
            .frame(width: 364 * k, alignment: .leading)
            .position(x: 182 * k + 8, y: y(0.27) + (2 * (tile + 34 * k) + 10 * k) / 2)
            VStack(spacing: 10 * k) {   // Play above the counter
                Button(action: onPlay) {
                    HStack(spacing: 10 * k) { Image(systemName: "leaf.fill"); Text("Play") }
                        .font(Dream.font(28 * k, .semibold)).foregroundStyle(.white)
                        .frame(width: 230 * k, height: 64 * k)
                        .background(Capsule().fill(Dream.orange))
                        .overlay(Capsule().strokeBorder(.white, lineWidth: 5))
                        .background(Capsule().fill(Dream.orangeDark).offset(y: 6))
                }
                .buttonStyle(DreamPress()).disabled(checking).opacity(checking ? 0.7 : 1)
                if checking {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the cloud save…") }
                        Button("Play without it", action: onPlayWithoutCloud).foregroundStyle(Dream.orangeDark)
                    }
                    .font(Dream.font(12)).foregroundStyle(Dream.ink).padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.9)))
                }
            }
            .position(x: x(0.785), y: y(0.42))
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
    }

    @ViewBuilder private func crannyTile(_ s: Setting, _ size: CGFloat) -> some View {
        let t = CrannyTile(symbol: Dream.symbol(s.env), value: value(s), caption: s.label, colour: Self.tileColour[s.env] ?? Dream.orange, size: size)
        Group {
            if s.kind == "choice" {
                Menu { Picker(s.label, selection: m.binding(s)) { ForEach(offeredOptions(s, current: m.values[s.env]), id: \.[0]) { Text($0[1]).tag($0[0]) } } } label: { t }
            } else {
                Button { m.values[s.env] = (m.values[s.env] ?? s.def) == s.onValue ? s.offValue : s.onValue } label: { t }
            }
        }
        .buttonStyle(DreamPress())
        .disabled(m.fixed.contains(s.env))
        .accessibilityLabel("\(s.label): \(value(s))")
    }

    // ---------- The panel ----------

    private func open(_ page: String) { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { tab = page } }
    private func close() { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { tab = nil }; refreshCloud() }

    private func panel(_ size: CGSize) -> some View {
        let wide = size.width >= size.height
        return ZStack(alignment: .bottom) {
            Dream.dim.opacity(0.35).ignoresSafeArea().onTapGesture(perform: close).transition(.opacity)
            VStack(spacing: 0) {
                VStack(spacing: 8) {   // the grabber and the title: dragged down, the panel closes
                    Capsule().fill(Dream.rim).frame(width: 40, height: 5).padding(.top, 8)
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(Dream.orange)
                        Text("All settings").font(Dream.font(17, .semibold)).foregroundStyle(Dream.ink)
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Dream.iconInk)
                                .frame(width: 30, height: 30).background(Circle().fill(Dream.rim))
                        }
                        .buttonStyle(DreamPress())
                        .accessibilityLabel("Close")
                    }
                }
                .padding(.horizontal, 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height > 60 { close() } })
                tabs.padding(.top, 10).padding(.bottom, 4)
                pageList
            }
            .frame(width: wide ? min(600, size.width - 24) : size.width, height: wide ? size.height * 0.9 : size.height * 0.82)
            .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous).fill(Dream.cream).ignoresSafeArea(edges: .bottom))
            .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous).fill(Dream.island ? Dream.shopOrange : Dream.cream).offset(y: -6).ignoresSafeArea(edges: .bottom))   // island: the shop's orange edge
            .transition(.move(edge: .bottom))
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(m.sections.filter { !m.rows(in: $0).isEmpty } + [Self.modsTab, Self.savesTab], id: \.self) { page in
                    let on = tab == page
                    Button { tab = page } label: {
                        Label(page, systemImage: Dream.sectionSymbol(page))
                            .font(Dream.font(12)).foregroundStyle(on ? Color.white : Dream.iconInk)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(on ? Dream.orange : Color.white))
                            .overlay(Capsule().strokeBorder(on ? Dream.orange : Dream.rim, lineWidth: 2))
                    }
                    .buttonStyle(DreamPress())
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var pageList: some View {
        List {
            if tab == Self.modsTab {
                ModsPage(store: mods, picking: $modPicking, deleting: $modDeleting, editing: $modEditing, accent: Dream.orange, soft: Dream.soft)
            } else if tab == Self.savesTab {
                Section {
                    Button("Reset to tested defaults") { m.reset() }.disabled(!m.changed)
                } footer: {
                    Text("Brings back all settings this game was tested with.").foregroundStyle(Dream.soft)
                }
                .listRowBackground(Color.white)
                CloudSavesSection(checking: checking)
                    .listRowBackground(Color.white)
                Section {
                    HStack {
                        Label("Memory available", systemImage: "memorychip")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(Dream.soft)
                    }
                }
                .listRowBackground(Color.white)
            } else if let tab {
                Section {
                    ForEach(m.rows(in: tab)) { s in
                        HStack(spacing: 12) {
                            Image(systemName: Dream.symbol(s.env)).foregroundStyle(Dream.orange).frame(width: 22)
                            SettingRow(s: s, m: m)
                        }
                    }
                }
                .listRowBackground(Color.white)
            }
        }
        .environment(\.editMode, .constant(modEditing && tab == Self.modsTab ? .active : .inactive))
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .contentMargins(.top, 4, for: .scrollContent)   // the grouped list's own top inset left an empty band under the tabs
        .font(Dream.font(14, .regular))
        .foregroundStyle(Dream.ink)
    }
}
