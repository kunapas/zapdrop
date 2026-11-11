import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZapdropAppModel
import ZapdropCore

/// Dragging phone items into Finder (or any app that accepts files). The item provider promises a file;
/// when the drop lands, Zapdrop copies the item through its normal transfer engine and hands over the result.
@MainActor
enum FinderDrag {
    static func provider(for item: RemoteItem, model: Model) -> NSItemProvider? {
        guard model.monitor.state.isReady else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = FileNameSanitizer.sanitize(item.name).name
        let type: UTType
        if item.isFolder {
            type = .folder
        } else {
            let ext = FileNameSanitizer.splitExtension(item.name).ext.dropFirst()
            type = UTType(filenameExtension: String(ext)) ?? .data
        }
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1000)
            Task { @MainActor in
                do {
                    let url = try await model.exportForDrag(item) { fraction in
                        progress.completedUnitCount = Int64(fraction * 1000)
                    }
                    progress.completedUnitCount = 1000
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}
