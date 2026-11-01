import Photos
import CoreLocation
import Vision
import UIKit
import SwiftUI

func fmt(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct Item: Identifiable, Hashable {
    let asset: PHAsset
    let size: Int64
    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PlaceGroup: Identifiable {
    let id: String
    var name: String
    let location: CLLocation?
    var items: [Item]
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor
final class Library: ObservableObject {
    @Published var authorized = false
    @Published var denied = false
    @Published var scanning = false
    @Published var progress = 0.0
    @Published var items: [Item] = []
    @Published var bySize: [Item] = []
    @Published var places: [PlaceGroup] = []
    @Published var duplicateGroups: [[Item]] = []
    @Published var similarGroups: [[Item]] = []
    @Published var analyzingSimilar = false
    @Published var similarDone = false
    @Published var selected = Set<String>()
    @Published var message: String?

    private var placeNames: [String: String] = [:]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var videoBytes: Int64 { items.filter { $0.isVideo }.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func start() async {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .authorized || s == .limited {
            authorized = true
            await scan()
        }
    }

    func requestAccess() async {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = (s == .authorized || s == .limited)
        denied = !authorized
        if authorized { await scan() }
    }

    nonisolated static func fileSize(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for r in resources {
            if let n = r.value(forKey: "fileSize") as? NSNumber { total += n.int64Value }
        }
        return total
    }

    func scan() async {
        scanning = true
        progress = 0
        selected = []
        let list: [Item] = await Task.detached(priority: .userInitiated) { [weak self] () -> [Item] in
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetch = PHAsset.fetchAssets(with: opts)
            let total = max(fetch.count, 1)
            var out = [Item]()
            out.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, idx, _ in
                out.append(Item(asset: asset, size: Library.fileSize(asset)))
                if idx % 250 == 0 {
                    let p = Double(idx) / Double(total)
                    Task { @MainActor in self?.progress = p }
                }
            }
            return out
        }.value
        items = list
        rebuild()
        scanning = false
        geocodeTopPlaces()
    }

    private func rebuild() {
        bySize = items.sorted { $0.size > $1.size }
        buildDuplicates()
        buildPlaces()
    }

    private func buildDuplicates() {
        var dict = [String: [Item]]()
        for it in items where it.size > 0 {
            let a = it.asset
            guard let d = a.creationDate else { continue }
            let key = "\(a.mediaType.rawValue)|\(a.pixelWidth)x\(a.pixelHeight)|\(Int(d.timeIntervalSince1970))|\(Int(a.duration * 10))|\(it.size)"
            dict[key, default: []].append(it)
        }
        duplicateGroups = dict.values
            .filter { $0.count > 1 }
            .sorted { groupBytes($0) > groupBytes($1) }
    }

    func groupBytes(_ g: [Item]) -> Int64 { g.reduce(0) { $0 + $1.size } }

    private func buildPlaces() {
        var dict = [String: [Item]]()
        for it in items {
            if let loc = it.asset.location {
                let k = "\(Int((loc.coordinate.latitude * 20).rounded()))_\(Int((loc.coordinate.longitude * 20).rounded()))"
                dict[k, default: []].append(it)
            } else {
                dict["none", default: []].append(it)
            }
        }
        var out = [PlaceGroup]()
        for (k, v) in dict {
            let loc = v.first?.asset.location
            var name = "Sans lieu"
            if k != "none" {
                if let cached = placeNames[k] {
                    name = cached
                } else if let c = loc?.coordinate {
                    name = String(format: "%.2f°, %.2f°", c.latitude, c.longitude)
                }
            }
            out.append(PlaceGroup(id: k, name: name, location: loc, items: v))
        }
        places = out.sorted { $0.bytes > $1.bytes }
    }

    private func geocodeTopPlaces() {
        let targets = places.prefix(40).filter { $0.id != "none" && placeNames[$0.id] == nil }
        let jobs = targets.map { ($0.id, $0.location) }
        Task {
            let geocoder = CLGeocoder()
            for (key, loc) in jobs {
                guard let loc = loc else { continue }
                if let marks = try? await geocoder.reverseGeocodeLocation(loc), let m = marks.first {
                    let name = [m.locality ?? m.name, m.country].compactMap { $0 }.joined(separator: ", ")
                    if !name.isEmpty {
                        placeNames[key] = name
                        if let i = places.firstIndex(where: { $0.id == key }) { places[i].name = name }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
        }
    }

    // MARK: Sélection

    func toggle(_ item: Item) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func selectAllButFirst(in groups: [[Item]]) {
        for g in groups { for it in g.dropFirst() { selected.insert(it.id) } }
    }

    func clearSelection() { selected = [] }

    // MARK: Suppression (confirmation système iOS, puis « Supprimés récemment »)

    func deleteSelected() async {
        let doomed = items.filter { selected.contains($0.id) }
        guard !doomed.isEmpty else { return }
        let assets = doomed.map { $0.asset } as NSArray
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            let gone = Set(doomed.map { $0.id })
            items.removeAll { gone.contains($0.id) }
            similarGroups = similarGroups.map { $0.filter { !gone.contains($0.id) } }.filter { $0.count > 1 }
            selected = []
            rebuild()
            message = "\(doomed.count) éléments déplacés dans « Supprimés récemment »."
        } catch {
            message = "Suppression annulée."
        }
    }

    // MARK: Photos similaires (rafales et séries)

    func analyzeSimilar() async {
        analyzingSimilar = true
        let photos = items
            .filter { $0.asset.mediaType == .image && $0.asset.creationDate != nil }
            .sorted { $0.asset.creationDate! < $1.asset.creationDate! }
        let groups: [[Item]] = await Task.detached(priority: .userInitiated) { () -> [[Item]] in
            var runs = [[Item]]()
            var current = [Item]()
            for it in photos {
                if let last = current.last,
                   it.asset.creationDate!.timeIntervalSince(last.asset.creationDate!) > 120 {
                    if current.count >= 2 { runs.append(current) }
                    current = []
                }
                current.append(it)
            }
            if current.count >= 2 { runs.append(current) }

            var result = [[Item]]()
            let manager = PHImageManager.default()
            let opts = PHImageRequestOptions()
            opts.isSynchronous = true
            opts.deliveryMode = .fastFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false

            for run in runs {
                let part = Array(run.prefix(40))
                var prints = [(Item, VNFeaturePrintObservation)]()
                for it in part {
                    var cg: CGImage?
                    manager.requestImage(for: it.asset, targetSize: CGSize(width: 256, height: 256),
                                         contentMode: .aspectFit, options: opts) { img, _ in
                        cg = img?.cgImage
                    }
                    guard let image = cg else { continue }
                    let req = VNGenerateImageFeaturePrintRequest()
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try? handler.perform([req])
                    if let obs = req.results?.first as? VNFeaturePrintObservation {
                        prints.append((it, obs))
                    }
                }
                var clusters = [[(Item, VNFeaturePrintObservation)]]()
                for p in prints {
                    var placed = false
                    for i in clusters.indices {
                        var d: Float = 0
                        if (try? clusters[i][0].1.computeDistance(&d, to: p.1)) != nil, d < 0.45 {
                            clusters[i].append(p)
                            placed = true
                            break
                        }
                    }
                    if !placed { clusters.append([p]) }
                }
                for c in clusters where c.count >= 2 {
                    // la plus grosse photo en premier : c'est celle à garder
                    result.append(c.map { $0.0 }.sorted { $0.size > $1.size })
                }
            }
            return result.sorted { a, b in
                a.reduce(0) { $0 + $1.size } > b.reduce(0) { $0 + $1.size }
            }
        }.value
        similarGroups = groups
        similarDone = true
        analyzingSimilar = false
    }
}
