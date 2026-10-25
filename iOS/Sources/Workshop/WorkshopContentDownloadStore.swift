// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

struct SteamTransportStatus: Decodable {
    let phase: String
    let received: UInt64
    let total: UInt64
    let message: String
    let guard_type: String
    var isTerminal: Bool { ["done", "error", "cancelled"].contains(phase) }
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

/// Exactly one operation owns its staging directory until native I/O is terminal
/// AND the library import has completed. Browser cookies never authorize this path.
@MainActor @Observable
final class WorkshopContentDownloadStore {
    private(set) var status: SteamTransportStatus?
    private(set) var signedIn = false
    private(set) var isBusy = false
    private(set) var isImporting = false
    private(set) var cancellationRequested = false
    private(set) var errorText: String?
    private(set) var currentItemID: String?
    private var taskID: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private weak var library: LibraryStore?
    private var jobFolder: URL?
    var canCancel: Bool { taskID != 0 && isBusy && !cancellationRequested && !isImporting }

    init(library: LibraryStore) { self.library = library }

    /// Copies credentials synchronously across the C boundary; no async Swift
    /// task retains the form's password or JSON payload while waiting for Guard.
    func signIn(account: String, password: String) {
        guard !isBusy else { return }
        guard let id = start(["operation": "login", "account": account, "password": password]) else { return }
        pollTask = Task { await monitor(id, operation: "login", item: nil) }
    }

    func download(_ item: WorkshopItem) async {
        guard !isBusy else { return }
        guard signedIn else { errorText = Self.localizedError("content_signin_required"); return }
        guard WorkshopParsing.isWorkshopID(item.id), !item.isCollection, !item.isApplication else {
            errorText = Self.localizedError("item_type_unsupported"); return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopDownload-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.id, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { errorText = Self.localizedError("write_failed"); return }
        jobFolder = folder
        guard let id = start(["operation": "download", "item_id": item.id, "destination": folder.path]) else {
            cleanupOwnedFolder(); return
        }
        currentItemID = item.id
        pollTask = Task { await monitor(id, operation: "download", item: item) }
        await pollTask?.value
    }

    func submitGuard(_ code: String) -> Bool {
        guard taskID != 0, status?.phase == "guard", !cancellationRequested else { return false }
        return code.withCString { wm_steam_guard(taskID, $0) != 0 }
    }

    func cancel() {
        guard canCancel else { return }
        cancellationRequested = true
        wm_steam_cancel(taskID)
        // Never cancel the polling task or remove the folder while native writes
        // may still be in flight. Completion and cancellation may race.
    }

    func signOut() {
        guard !isBusy else { return }
        let id = Self.startNative(["operation": "logout"])
        guard id != 0 else { errorText = Self.localizedError("busy"); return }
        signedIn = false; status = nil; errorText = nil; currentItemID = nil
    }

    private static func startNative(_ request: [String: String]) -> UInt64 {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let payload = String(data: data, encoding: .utf8) else { return 0 }
        return payload.withCString { wm_steam_start($0) }
    }

    private func start(_ request: [String: String]) -> UInt64? {
        guard !isBusy else { return nil }
        let id = Self.startNative(request)
        guard id != 0 else { errorText = Self.localizedError("busy"); return nil }
        taskID = id; status = nil; errorText = nil
        isBusy = true; isImporting = false; cancellationRequested = false
        return id
    }

    private func monitor(_ id: UInt64, operation: String, item: WorkshopItem?) async {
        let deadline = Date().addingTimeInterval(operation == "login" ? 240 : 1_800)
        while taskID == id {
            if Date() >= deadline && !cancellationRequested {
                errorText = Self.localizedError(operation == "login" ? "login_timeout" : "download_timeout")
                cancel()
            }
            if let pointer = wm_steam_poll(id) {
                let text = String(cString: pointer)
                wm_steam_free(pointer)
                if let data = text.data(using: .utf8), let result = try? JSONDecoder().decode(SteamTransportStatus.self, from: data) {
                    status = result
                    if result.isTerminal {
                        // Native is finished even if a done/error won the race
                        // with cancellation. It is now safe to clean our staging.
                        taskID = 0
                        if cancellationRequested || result.phase == "cancelled" {
                            if operation == "login", result.phase == "done" { _ = Self.startNative(["operation": "logout"]) }
                            cleanupOwnedFolder(); finish(); return
                        }
                        if result.phase == "error" {
                            errorText = Self.localizedError(result.message)
                            cleanupOwnedFolder(); finish(); return
                        }
                        if operation == "login" { signedIn = true; finish(); return }
                        if let item { await importCompletedDownload(item) }
                        finish(); return
                    }
                }
            }
            // This task is deliberately not cancelled while native I/O owns the
            // folder. The app may hide the sheet without abandoning the download.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func importCompletedDownload(_ item: WorkshopItem) async {
        guard let folder = jobFolder, let library,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {
            errorText = Self.localizedError("wallpaper_project_missing"); cleanupOwnedFolder(); return
        }
        isImporting = true
        // Keep the operation busy through this await; no second job can replace
        // jobFolder or report an old item's download as the current one.
        library.errorMessage = nil
        await library.importURL(folder)
        if library.errorMessage != nil || !library.items.contains(where: { $0.workshopID == item.id }) {
            errorText = Self.localizedError("import_failed")
        } else {
            errorText = nil
        }
        cleanupOwnedFolder()
    }

    private func finish() {
        isBusy = false; isImporting = false; cancellationRequested = false
        taskID = 0; pollTask = nil
    }

    private func cleanupOwnedFolder() {
        guard let folder = jobFolder else { return }
        let base = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent() == base,
              target.lastPathComponent.hasPrefix("WorkshopDownload-"),
              UUID(uuidString: String(target.lastPathComponent.dropFirst("WorkshopDownload-".count))) != nil else { return }
        try? FileManager.default.removeItem(at: target)
        jobFolder = nil
    }

    private static func localizedError(_ reason: String) -> String {
        WorkshopContentDiagnostics.localizedError(reason)
    }
}
