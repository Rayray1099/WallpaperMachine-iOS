import Foundation

/// The filesystem and navigation boundary of one web wallpaper.
///
/// A web wallpaper is arbitrary author JavaScript running in WebKit. It may read
/// the project folder the user imported, and nothing else. These rules are
/// enforced here, in one place, so the web view delegate and the host message
/// channel cannot drift apart:
///
/// - the read root is the project directory (or the entry file's parent);
/// - the entry is resolved through `project.json` (`file`) or `index.html`;
/// - every resolved path is standardised and symlink-resolved before the
///   containment check, so a symlink cannot walk out of the root;
/// - the top frame may only stay on the entry document; any file outside the
///   root and any remote page is refused and reported;
/// - a file requested by the page (random file property) is accepted only when
///   it is a readable regular file under the same root.
enum WebWallpaperSecurity {
  struct Paths: Equatable {
    var root: URL
    var entry: URL
  }

  /// Why the project could not be opened. The view reports this without loading
  /// a blank page that looks like a working wallpaper.
  enum LoadError: Error, Equatable, LocalizedError {
    case notLocalFile
    case rootMissing
    case entryMissing(String)
    case entryOutsideRoot
    case projectFileInvalid(String)

    var errorDescription: String? {
      switch self {
      case .notLocalFile:
        return "A web wallpaper must be a local file or folder."
      case .rootMissing:
        return "The web wallpaper project folder no longer exists."
      case .entryMissing(let name):
        return "The web wallpaper entry \(name) is missing."
      case .entryOutsideRoot:
        return "The web wallpaper entry resolves outside its project folder."
      case .projectFileInvalid(let detail):
        return "The web wallpaper project.json is invalid: \(detail)"
      }
    }
  }

  enum Navigation: Equatable {
    case allow
    case cancel(Rejection)
  }

  enum Rejection: Equatable {
    /// An http(s) link the user would have to confirm.
    case external(URL)
    /// A local file outside the project root.
    case fileOutsideRoot(URL)
    /// A file inside the root that is not the entry document.
    case navigationAway(URL)
    case unsupportedScheme(String)
    case missingURL
  }

  /// Resolves the read root and entry. `url` may be the project directory or the
  /// entry file itself.
  static func paths(for url: URL, fileManager: FileManager = .default) throws -> Paths {
    guard url.isFileURL else { throw LoadError.notLocalFile }
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    let canonicalURL = canonical(url)

    if exists, isDirectory.boolValue {
      let root = canonicalURL
      let entryName = try entryName(in: root, fileManager: fileManager)
      let entry = canonical(root.appendingPathComponent(entryName))
      guard isContained(entry, in: root) else { throw LoadError.entryOutsideRoot }
      guard fileManager.fileExists(atPath: entry.path) else {
        throw LoadError.entryMissing(entryName)
      }
      return Paths(root: root, entry: entry)
    }

    let root = canonical(url.deletingLastPathComponent())
    guard fileManager.fileExists(atPath: root.path) else { throw LoadError.rootMissing }
    let entry = canonicalURL
    guard fileManager.fileExists(atPath: entry.path) else {
      throw LoadError.entryMissing(entry.lastPathComponent)
    }
    guard isContained(entry, in: root) else { throw LoadError.entryOutsideRoot }
    return Paths(root: root, entry: entry)
  }

  /// `project.json`'s `file`, else `index.html`. The value must be a relative
  /// path with no `..` component; the containment check catches symlink escapes
  /// after that.
  static func entryName(in root: URL, fileManager: FileManager = .default) throws -> String {
    let projectFile = root.appendingPathComponent("project.json")
    guard fileManager.fileExists(atPath: projectFile.path) else { return "index.html" }
    guard let data = try? Data(contentsOf: projectFile), data.count <= 2_000_000 else {
      throw LoadError.projectFileInvalid("it could not be read")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LoadError.projectFileInvalid("it is not a JSON object")
    }
    guard let name = object["file"] as? String else { return "index.html" }
    guard isSafeRelativePath(name) else {
      throw LoadError.projectFileInvalid("the file path is not inside the project")
    }
    return name
  }

  /// Whether a string is a project-relative path that cannot escape by itself.
  static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return false }
    guard !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
    return true
  }

  /// A navigation request from WebKit. Subframes are left alone: a wallpaper is
  /// allowed to embed remote content the way Wallpaper Engine's Chromium host
  /// lets it, and a subframe cannot drive the app's UI. The top frame stays on
  /// the entry document, and anything external is for the host to confirm.
  static func navigation(for url: URL?, isMainFrame: Bool, entry: URL, root: URL) -> Navigation {
    guard isMainFrame else { return .allow }
    guard let url else { return .cancel(.missingURL) }
    let sameEntry = withoutFragment(url).standardizedFileURL == withoutFragment(entry).standardizedFileURL
    if url.isFileURL {
      if sameEntry { return .allow }
      let candidate = canonical(url)
      if isContained(candidate, in: root) { return .cancel(.navigationAway(candidate)) }
      return .cancel(.fileOutsideRoot(candidate))
    }
    switch url.scheme?.lowercased() {
    case "http", "https":
      return .cancel(.external(url))
    case "about", "data", "blob":
      // An `about:blank` top frame is WebKit tearing a page down; data and blob
      // documents are not navigation away from the app.
      return .cancel(.navigationAway(url))
    default:
      return .cancel(.unsupportedScheme(url.scheme ?? "none"))
    }
  }

  /// A page-requested file (a `file` or `directory` property value). The page
  /// may name an absolute path inside the root or a project-relative one; any
  /// other path, a directory, or a path that escapes through a symlink is
  /// refused.
  static func containedFile(
    _ path: String, root: URL, fileManager: FileManager = .default
  ) -> URL? {
    guard !path.isEmpty else { return nil }
    let candidate: URL
    if path.hasPrefix("file://"), let parsed = URL(string: path) {
      candidate = parsed
    } else if path.hasPrefix("/") {
      candidate = URL(fileURLWithPath: path)
    } else {
      guard isSafeRelativePath(path) else { return nil }
      candidate = root.appendingPathComponent(path)
    }
    let canonicalCandidate = canonical(candidate)
    guard isContained(canonicalCandidate, in: canonical(root)) else { return nil }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: canonicalCandidate.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return canonicalCandidate
  }

  /// Standardised and symlink-resolved. A file URL that no longer exists still
  /// standardises, so containment can be checked before reporting a missing
  /// entry.
  static func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  /// The value a Wallpaper Engine page turns into `file:///` + value, matching
  /// the desktop host: an absolute POSIX path without its leading separator,
  /// with the three characters that would re-scope a URL escaped. A page that
  /// treats the value as a plain path still sees spaces and non-ASCII intact.
  static func pageValue(for url: URL) -> String {
    var value = url.path
    if value.hasPrefix("/") { value.removeFirst() }
    return
      value
      .replacingOccurrences(of: "%", with: "%25")
      .replacingOccurrences(of: "#", with: "%23")
      .replacingOccurrences(of: "?", with: "%3F")
  }

  /// Whether `candidate` is `root` itself or lives below it. Both must already
  /// be canonical.
  static func isContained(_ candidate: URL, in root: URL) -> Bool {
    let rootComponents = root.pathComponents
    let components = candidate.pathComponents
    guard components.count > rootComponents.count else { return false }
    return Array(components.prefix(rootComponents.count)) == rootComponents
  }

  static func withoutFragment(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.fragment = nil
    return components.url ?? url
  }
}
