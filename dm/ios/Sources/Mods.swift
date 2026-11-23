// Mods: replacement game files from the player (Documents/mods/<name>/romfs/..., the usual Switch layout), served over the game's files when they are on (dm/host/mods.h).
// From the kid-with-sword-remake port (its Mods panel); here a page of the launcher's settings panel (LauncherDream.swift ModsPage), with a Mods tile on the Cranny layout. The page has: Import Mod (a .zip), Import Folder, a .zip copied into the mods folder with Files, the installed mods with a switch each, their order
// (the higher one wins when two change the same file) and delete. The order and the mods turned off are kept in UserDefaults; a mod folder put into Documents/mods with
// the Files app shows up too, on. At Play, DM_MODS lists the romfs folders of the mods that are on, top first (ModStore.applyEnv); with none on it is unset and the game
// starts exactly as without this feature.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ModStore: ObservableObject {
    struct Mod: Identifiable, Equatable {
        let id: String            // its folder's name
        var on: Bool
        var valid: Bool           // it has a romfs folder (and a name the list can carry)
        var files = 0
        var bytes: Int64 = 0
        var note = ""             // what the check found
        var warn = false
    }
    static let shared = ModStore()
    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mods", isDirectory: true) }
    private static let orderKey = "dm.mods.order", offKey = "dm.mods.off"

    @Published private(set) var mods: [Mod] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private var generation = 0

    var enabledCount: Int { mods.filter { $0.on && $0.valid }.count }

    init() { mods = Self.scan() }

    /// The folders in Documents/mods (hidden ones are the host's), in the saved order, then new ones by name; each on unless turned off
    static func scan() -> [Mod] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { n in
            var d: ObjCBool = false
            return !n.hasPrefix(".") && fm.fileExists(atPath: dir.appendingPathComponent(n).path, isDirectory: &d) && d.boolValue
        }
        let defaults = UserDefaults.standard
        let order = defaults.stringArray(forKey: orderKey) ?? [], off = Set(defaults.stringArray(forKey: offKey) ?? [])
        let listed = order.filter(names.contains) + names.filter { !order.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return listed.map { n in
            var d: ObjCBool = false
            let romfs = fm.fileExists(atPath: dir.appendingPathComponent(n).appendingPathComponent("romfs").path, isDirectory: &d) && d.boolValue
            return Mod(id: n, on: !off.contains(n), valid: romfs && !n.contains(":"))   // DM_MODS is ':'-separated
        }
    }
    /// DM_MODS for the host: the romfs folders of the mods that are on, top of the list first. Unset when none is on
    @discardableResult static func applyEnv() -> Int {
        let on = scan().filter { $0.on && $0.valid }.map { dir.appendingPathComponent($0.id).appendingPathComponent("romfs").path }
        if on.isEmpty { unsetenv("DM_MODS") } else { setenv("DM_MODS", on.joined(separator: ":"), 1) }
        fputs("launcher: \(on.count) mod(s) on\n", stderr)
        return on.count
    }

    func reload() {
        var list = Self.scan()
        for i in list.indices { if let old = mods.first(where: { $0.id == list[i].id }) { list[i].files = old.files; list[i].bytes = old.bytes; list[i].note = old.note; list[i].warn = old.warn } }
        mods = list; save(); check()
    }
    private func save() {
        UserDefaults.standard.set(mods.map(\.id), forKey: Self.orderKey)
        UserDefaults.standard.set(mods.filter { !$0.on }.map(\.id), forKey: Self.offKey)
    }
    func setOn(_ id: String, _ on: Bool) {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { return }
        mods[i].on = on; save(); check()
    }
    func move(from: IndexSet, to: Int) { mods.move(fromOffsets: from, toOffset: to); save(); check() }
    func delete(_ id: String) {
        do { try FileManager.default.removeItem(at: Self.dir.appendingPathComponent(id)) } catch { message = "\(id) couldn't be deleted: \(error.localizedDescription)" }
        reload()
    }

    /// Each mod's files, size and what the size table makes of it (dm_mods_check), and which of its files a mod above it that is on also has
    private func check() {
        generation += 1
        let gen = generation, list = mods
        DispatchQueue.global(qos: .utility).async {
            var seen: [String: String] = [:]   // file → the first mod that is on and has it
            var out = list
            for i in out.indices {
                let m = out[i]
                guard m.valid else {
                    out[i].note = m.id.contains(":") ? "Its name has a colon (:). Rename the folder in the Files app." : "No romfs folder inside, so it isn't used. A mod's files go in a folder named romfs."
                    out[i].warn = true; continue
                }
                let romfs = Self.dir.appendingPathComponent(m.id).appendingPathComponent("romfs")
                var files: [String] = [], bytes: Int64 = 0
                if let e = FileManager.default.enumerator(atPath: romfs.path) {   // paths relative to romfs (the host skips hidden names at every level, so this does)
                    while let rel = e.nextObject() as? String {
                        guard let a = e.fileAttributes, a[.type] as? FileAttributeType == .typeRegular, !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                        files.append(rel); bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
                    }
                }
                var c = [Int32](repeating: 0, count: 6)
                romfs.path.withCString { dm_mods_check($0, &c) }
                var lines = ["\(files.count) file\(files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"]
                var warn = false
                if c[3] > 0 { lines.append("\(c[3]) file\(c[3] == 1 ? " is" : "s are") bigger than the game has room for. The game may crash when it loads \(c[3] == 1 ? "it" : "them")."); warn = true }
                else if c[5] != 0 && c[1] > 0 && c[4] > 0 { lines.append("\(c[1]) file\(c[1] == 1 ? " is" : "s are") bigger than the original\(c[1] == 1 ? "" : "s"). The mod's own size table makes room for \(c[1] == 1 ? "it" : "them").") }
                else if c[5] != 0 && c[1] > 0 { lines.append("\(c[1]) file\(c[1] == 1 ? " is" : "s are") bigger than the original\(c[1] == 1 ? "" : "s") and the mod has no size table. If the game crashes loading \(c[1] == 1 ? "it" : "them"), turn this mod off."); warn = true }
                else if c[2] > 0 { lines.append("\(c[2]) file\(c[2] == 1 ? " is" : "s are") bigger than the original\(c[2] == 1 ? "" : "s"). The game's size table makes room for \(c[2] == 1 ? "it" : "them") when you press Play.") }
                if c[4] > 0 && c[5] == 0 { lines.append("Brings its own copy of the game's size table. The app uses its own merged table instead.") }
                if m.on {
                    var under: [String: Int] = [:]
                    for f in files { if let top = seen[f] { under[top, default: 0] += 1 } else { seen[f] = m.id } }
                    for (top, n) in under.sorted(by: { $0.key < $1.key }) { lines.append("\(n) of its files are also in \(top), higher in the list, so \(top)'s are used.") }
                }
                out[i].files = files.count; out[i].bytes = bytes; out[i].note = lines.joined(separator: "\n"); out[i].warn = warn
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                for o in out { if let i = self.mods.firstIndex(where: { $0.id == o.id }) { self.mods[i].files = o.files; self.mods[i].bytes = o.bytes; self.mods[i].note = o.note; self.mods[i].warn = o.warn } }
            }
        }
    }

    /// Imports what the Files picker gave: .zip files or folders (several when the picker allows several: LiveContainer turns that on). Each is opened here, on the picker's
    /// callback, before anything else can move it (a copy in the app's Inbox, or a folder opened in place), then read by dm_mods_import, which takes a folder as it is.
    /// No NSFileCoordinator: in LiveContainer the app runs under the host's identity, and the picked file never reached the import (the owner's iPhone, L7.5-mods)
    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { fputs("launcher: mods: the picker gave nothing\n", stderr); return }
        let fm = FileManager.default
        let picked: [(url: URL, scoped: Bool)] = urls.map { u in
            let scoped = u.startAccessingSecurityScopedResource()
            var d: ObjCBool = false
            let there = fm.fileExists(atPath: u.path, isDirectory: &d)
            fputs("launcher: mods: picked \(u.path) (\(there ? (d.boolValue ? "folder" : "file") : "NOT READABLE"), security scope \(scoped ? "yes" : "no"))\n", stderr)
            return (u, scoped)
        }
        busy = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var added: [String] = [], notes: [String] = []
            for p in picked {
                var d: ObjCBool = false
                let folder = fm.fileExists(atPath: p.url.path, isDirectory: &d) && d.boolValue
                let r = Self.importZip(p.url.path, name: folder ? p.url.lastPathComponent : p.url.deletingPathExtension().lastPathComponent)
                added += r.added
                if !r.msg.isEmpty { notes.append(urls.count > 1 ? "\(p.url.lastPathComponent): \(r.msg)" : r.msg) }
                if p.scoped { p.url.stopAccessingSecurityScopedResource() }
                if p.url.path.contains("-Inbox/") || p.url.path.hasPrefix(fm.temporaryDirectory.path) { try? fm.removeItem(at: p.url) }   // the picker's copy
            }
            DispatchQueue.main.async { self.finish(added: added, notes: notes) }
        }
    }
    /// .zip files put straight into the mods folder with the Files app (the way in when the picker does not work): imported when the panel opens, then removed.
    /// One that can't be imported is renamed <name>.not-imported, so it is not tried again each time
    func importDropped() {
        guard !busy else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: Self.dir.path)) ?? []).filter { n in
            var d: ObjCBool = false
            return !n.hasPrefix(".") && !n.hasSuffix(".not-imported") && fm.fileExists(atPath: Self.dir.appendingPathComponent(n).path, isDirectory: &d) && !d.boolValue
        }
        guard !files.isEmpty else { return }
        busy = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var added: [String] = [], notes: [String] = []
            for f in files {
                let u = Self.dir.appendingPathComponent(f)
                fputs("launcher: mods: \(f) in the mods folder: importing\n", stderr)
                let r = Self.importZip(u.path, name: u.deletingPathExtension().lastPathComponent)
                added += r.added
                if r.count > 0 { try? fm.removeItem(at: u) } else { try? fm.moveItem(at: u, to: u.appendingPathExtension("not-imported")) }
                if !r.msg.isEmpty { notes.append("\(f): \(r.msg)") }
            }
            DispatchQueue.main.async { self.finish(added: added, notes: notes) }
        }
    }
    private func finish(added: [String], notes: [String]) {
        busy = false
        if !added.isEmpty {   // new mods go to the top, on
            let order = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
            UserDefaults.standard.set(added + order.filter { !added.contains($0) }, forKey: Self.orderKey)
        }
        message = ((added.isEmpty ? [] : ["Added \(added.joined(separator: ", "))."]) + notes).joined(separator: " ")
        reload()
    }
    /// Where the mods folder is in the Files app: On My iPhone › the app, then the folders under its Documents (in LiveContainer, the guest app's data folder inside the host's)
    static var filesLocation: String {
        let parts = dir.path.components(separatedBy: "/")
        if let i = parts.firstIndex(of: "Containers"), i + 5 < parts.count, parts[i + 4] == "Documents" {   // /var/mobile/Containers/Data/Application/<UUID>/Documents/...
            return (["On My iPhone", Bundle.main.bundlePath.contains("/Documents/Applications/") ? "LiveContainer" : "this app"] + parts[(i + 5)...]).joined(separator: " › ")
        }
        return dir.path
    }
    private static func importZip(_ path: String, name: String) -> (count: Int, msg: String, added: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var msg = [CChar](repeating: 0, count: 1024), added = [CChar](repeating: 0, count: 4096)
        let n = dm_mods_import(path, dir.path, name, &msg, msg.count, &added, added.count)
        fputs("launcher: mods: import \(path): \(n) added: \(String(cString: msg))\n", stderr)
        return (Int(n), String(cString: msg), String(cString: added).split(separator: "\n").map(String.init))
    }
}

/// The Mods page of the launcher's panel (LauncherDream.swift): import a .zip or a folder, the installed mods with a switch each, their order (top wins) and delete
struct ModsPage: View {
    @ObservedObject var store: ModStore
    @Binding var picking: ModPicker.Kind?
    @Binding var deleting: ModStore.Mod?
    @Binding var editing: Bool
    var accent: Color
    var soft: Color

    var body: some View {
        Section {
            Button { picking = .file } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import mod")
                        Text("A .zip file from Files").font(.caption).foregroundStyle(soft)
                    }
                    Spacer()
                    if store.busy { ProgressView() }
                }
            }
            .disabled(store.busy)
            Button { picking = .folder } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import folder")
                        Text("A mod folder with romfs inside").font(.caption).foregroundStyle(soft)
                    }
                }
            }
            .disabled(store.busy)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let m = store.message, !m.isEmpty { Text(m).foregroundStyle(accent) }
                Text("Mods use the Switch layout: <name>/romfs/... You can also copy a .zip or a mod folder into \(ModStore.filesLocation) with the Files app.").foregroundStyle(soft)
            }
        }
        .listRowBackground(Color.white)
        if !store.mods.isEmpty {
            Section {
                ForEach(store.mods) { mod in
                    ModRow(mod: mod, soft: soft, on: Binding(get: { mod.on }, set: { store.setOn(mod.id, $0) }))
                        .swipeActions { Button(role: .destructive) { deleting = mod } label: { Label("Delete", systemImage: "trash") } }
                        .contextMenu { Button(role: .destructive) { deleting = mod } label: { Label("Delete", systemImage: "trash") } }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Installed · top of the list wins").foregroundStyle(soft)
                    Spacer()
                    if store.mods.count > 1 { Button(editing ? "Done" : "Change order") { withAnimation { editing.toggle() } }.foregroundStyle(accent) }
                }
            } footer: {
                Text("When two mods change the same file, the higher one is used. Mods load when you press Play; turn them all off to play the game as it is.").foregroundStyle(soft)
            }
            .listRowBackground(Color.white)
        }
    }
}

private struct ModRow: View {
    let mod: ModStore.Mod
    let soft: Color
    @Binding var on: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mod.id).lineLimit(2)
                if !mod.note.isEmpty {
                    Text(mod.note).font(.caption).foregroundStyle(mod.warn ? Color.orange : soft).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $on).labelsHidden().disabled(!mod.valid)
        }
        .padding(.vertical, 2)
    }
}

/// Files. A .zip (or another archive, so the import can say what it is) as a copy: the system copies it into the app first, so nothing has to be opened in place, which an
/// app in LiveContainer can't do (LiveContainer turns every picker into a copying one, and may allow several picks). A folder is opened in place where the system allows it.
struct ModPicker: UIViewControllerRepresentable {
    enum Kind: String, Identifiable { case file, folder; var id: String { rawValue } }
    let kind: Kind
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = kind == .folder
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .archive, .data] + ["7z", "rar"].compactMap { UTType(filenameExtension: $0) }, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        fputs("launcher: mods: \(kind.rawValue) picker shown\n", stderr)
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
