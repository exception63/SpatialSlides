//
//  DeckLoader.swift  →  loads a spatial "show" package.
//  Spatial Slides
//
//  A package is a `.sslides` folder produced by spatial-authoring/tools/
//  spatialize.mjs:  show.json + deck.html + thumb-NN.png + 3D assets.
//
//  Lookup on launch:
//    1. The last opened package in Documents/CurrentShow/ (import target).
//    2. A bundled package (show.json in the app bundle).
//    3. Show.empty (nothing loaded yet).
//
//  `baseURL` (the package folder) resolves show.json's relative paths — the
//  HTML, thumbnails, and 3D model assets all live beside it.
//

import Foundation

enum DeckLoader {

    /// The folder the loaded package came from (resolves html/thumbnails/assets).
    private(set) static var baseURL: URL?

    static let currentShowFolder = "CurrentShow"

    static func loadDefault() -> Show {
        if let docs = documentsURL() {
            let url = docs.appendingPathComponent("\(currentShowFolder)/show.json")
            if FileManager.default.fileExists(atPath: url.path), let show = load(contentsOf: url) { return show }
        }
        if let show = loadBundled() { return show }
        baseURL = nil
        return .empty
    }

    /// Imports a user-picked `.sslides` folder by copying it into Documents so it
    /// persists across launches and its paths resolve without a live security scope.
    static func importPickedShow(at pickedURL: URL) -> Show? {
        let fm = FileManager.default
        let accessed = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessed { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let docs = documentsURL() else { return nil }

        // Accept either the .sslides folder or a show.json inside it.
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: pickedURL.path, isDirectory: &isDir)
        let srcFolder = isDir.boolValue ? pickedURL : pickedURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: srcFolder.appendingPathComponent("show.json").path) else {
            print("DeckLoader: no show.json in picked package \(srcFolder.path)")
            return nil
        }
        let dest = docs.appendingPathComponent(currentShowFolder, isDirectory: true)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: srcFolder, to: dest)
        } catch {
            print("DeckLoader: import failed: \(error)")
            return nil
        }
        return load(contentsOf: dest.appendingPathComponent("show.json"))
    }

    /// Writes an edited show back to Documents/CurrentShow/show.json (where
    /// `loadDefault` reads first), keeping the sibling thumbnails/assets in place.
    @discardableResult
    static func save(_ show: Show) -> URL? {
        guard let docs = documentsURL() else { return nil }
        let dir = docs.appendingPathComponent(currentShowFolder, isDirectory: true)
        let url = dir.appendingPathComponent("show.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            try enc.encode(show).write(to: url, options: .atomic)
            return url
        } catch {
            print("DeckLoader: save failed: \(error)")
            return nil
        }
    }

    static func loadBundled() -> Show? {
        guard let url = Bundle.main.url(forResource: "show", withExtension: "json") else { return nil }
        return load(contentsOf: url)
    }

    @discardableResult
    static func load(contentsOf url: URL) -> Show? {
        let jsonURL = url.hasDirectoryPath ? url.appendingPathComponent("show.json") : url
        guard let data = try? Data(contentsOf: jsonURL) else {
            print("DeckLoader: could not read \(jsonURL.path)")
            return nil
        }
        do {
            let show = try JSONDecoder().decode(Show.self, from: data)
            baseURL = jsonURL.deletingLastPathComponent()
            return show
        } catch {
            print("DeckLoader: failed to decode show.json: \(error)")
            return nil
        }
    }

    /// Resolves a package-relative path (html / thumbnail / asset) against the
    /// loaded package folder, falling back to a bundled resource by base name.
    static func assetURL(_ relativePath: String) -> URL? {
        if let base = baseURL {
            let url = base.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let file = (relativePath as NSString).lastPathComponent
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext)
    }

    private static func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
