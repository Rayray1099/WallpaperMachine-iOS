// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension LibraryStore: PixivLibraryAccess {
    func installedPixivItem(workID: String, page: Int) -> WallpaperItem? {
        items.first { $0.pixiv?.id == workID && $0.pixiv?.page == page }
    }
    func importPixivProject(_ folder: URL) async throws {
        try await importURLReporting(folder)
    }
}
