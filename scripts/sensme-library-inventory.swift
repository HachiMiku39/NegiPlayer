import Foundation

// Read-only inventory using the same traversal policy as MediaIO.Scanner.
// Input JSON: {"roots":[absolute paths],"sources":[indexed absolute paths]}.
// Output may contain private music paths; capture it in application data.
@main struct SensMeInventory {
    struct Input: Decodable { let roots: [String]; let sources: [String] }
    struct Report: Encodable {
        let indexed: Int, existingCandidates: Int, indexedExisting: Int
        let missing: [String], unindexed: [String], enumerationErrors: [String]
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Inventory", code: 1) }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let indexed = Set(input.sources.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let extensions: Set<String> = ["mp3", "wav", "flac", "m4a", "dsf", "dff", "aif", "aiff", "aac", "iso"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var candidates = Set<String>(), errors: [String] = []
        for root in input.roots {
            let url = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                        errors.append(url.path + ": " + error.localizedDescription); return true
                    }) else { throw NSError(domain: "Inventory", code: 2) }
            for case let file as URL in files {
                guard extensions.contains(file.pathExtension.lowercased()) else { continue }
                do {
                    let values = try file.resourceValues(forKeys: Set(keys))
                    if values.isRegularFile == true, values.isSymbolicLink != true {
                        candidates.insert(file.resolvingSymlinksInPath().path)
                    }
                } catch { errors.append(file.path + ": " + error.localizedDescription) }
            }
        }
        let result = Report(indexed: indexed.count, existingCandidates: candidates.count,
                            indexedExisting: indexed.intersection(candidates).count,
                            missing: indexed.subtracting(candidates).sorted(),
                            unindexed: candidates.subtracting(indexed).sorted(), enumerationErrors: errors)
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }
}
