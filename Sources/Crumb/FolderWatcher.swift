import Foundation

/// Calls back, debounced, when entries are added to, removed from, or renamed in a folder (top level only).
@MainActor
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: Task<Void, Never>?

    init?(_ folder: URL, debounce: Duration = .seconds(1.5), onChange: @escaping @MainActor () -> Void) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pending?.cancel()
                self?.pending = Task {
                    try? await Task.sleep(for: debounce)
                    if !Task.isCancelled { onChange() }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
