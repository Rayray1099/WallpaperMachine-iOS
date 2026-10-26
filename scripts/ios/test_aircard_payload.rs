// SPDX-License-Identifier: GPL-3.0-only
// Appended to the external MIT AirCard source by prepare_aircard_validation.py.
// Tests the actual private ZIP builder; never opens a service or touches a device.
#[cfg(test)]
mod wm_posterboard_validation {
    use super::build_folder_archive;
    use std::collections::BTreeMap;
    use std::io::{Cursor, Read};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    const OPTIONS: &str = ".com.apple.posterkit.provider.contents.configurableOptions.plist";
    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
            let path = std::env::temp_dir().join(format!("wm-aircard-payload-{}-{stamp}-{}",
                std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn write(&self, relative: &str, data: &[u8]) {
            let path = self.0.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, data).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
    }

    fn payload(root: &Path) -> BTreeMap<String, Vec<u8>> {
        let bytes = build_folder_archive("/var/mobile/Containers/Data/Application/TEST/Library/descriptors", root)
            .expect("Actual AirCard build_folder_archive must produce the ZIP");
        let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        let mut result = BTreeMap::new();
        for index in 0..zip.len() {
            let mut entry = zip.by_index(index).unwrap();
            assert!(!entry.name().contains('\\'), "Windows separators leaked into ZIP: {}", entry.name());
            if entry.name().starts_with("payload/") && !entry.is_dir() {
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).unwrap();
                assert!(result.insert(entry.name().to_owned(), bytes).is_none(), "Duplicate member");
            }
        }
        result
    }

    #[test]
    fn hidden_options_and_all_three_planes_survive_exactly() {
        let fixture = Fixture::new();
        let mut expected = BTreeMap::new();
        let mut add = |path: &str, bytes: &[u8]| {
            fixture.write(path, bytes);
            expected.insert(format!("payload/{path}"), bytes.to_vec());
        };
        add("com.apple.posterkit.provider.descriptor.identifier", b"12345");
        add("versions/1/com.apple.posterkit.provider.instance.renderingConfiguration.plist", b"rendering\0original");
        add(&format!("versions/1/contents/{OPTIONS}"), b"bplist00\0exact-options\xff");
        add(&format!("versions/42/contents/{OPTIONS}"), b"second-version-options");
        add("versions/1/contents/com.apple.posterkit.provider.contents.userInfo", b"user-info-original");
        let wallpaper = "versions/1/contents/12345.Clownfish-834w-1210h@2x~ipad.wallpaper";
        add(&format!("{wallpaper}/Wallpaper.plist"), b"wallpaper-original");
        for role in ["Background", "Floating", "Foreground"] {
            for name in ["main.caml", "index.xml", "assetManifest.caml"] {
                let path = format!("{wallpaper}/12345.Clownfish_{role}-834w-1210h@2x~ipad.ca/{name}");
                add(&path, format!("unchanged-{role}-{name}").as_bytes());
            }
        }
        for index in 0..3 {
            let path = format!("{wallpaper}/12345.Clownfish_Background-834w-1210h@2x~ipad.ca/assets/{index:05}.jpg");
            add(&path, &[0xff, 0xd8, 0, index as u8, 0xfe, 0xff, 0xd9]);
        }
        add("visible unicode/畫面.bin", b"visible\0unchanged\xff");
        drop(add);
        // Every other dotfile and every junk/hidden subtree remains excluded.
        for path in [".DS_Store".to_owned(), "._Wallpaper.plist".to_owned(), OPTIONS.to_owned(),
            format!("versions/1/{OPTIONS}"), format!("versions/1/contents/{OPTIONS}.bak"),
            format!("versions/1/contents/nested/{OPTIONS}"),
            format!("wrapper/versions/1/contents/{OPTIONS}"),
            format!(".hidden/versions/1/contents/{OPTIONS}"),
            format!("versions/.hidden/contents/{OPTIONS}"),
            format!("versions/__MACOSX/contents/{OPTIONS}"),
            format!("versions/1/.hidden/{OPTIONS}"),
            format!("__MACOSX/versions/1/contents/{OPTIONS}"),
            "versions/1/contents/.other-hidden".to_owned(),
            "versions/1/contents/.hidden/visible.jpg".to_owned(),
            format!("versions/3/contents/{OPTIONS}/visible.txt")] {
            fixture.write(&path, b"must-not-ship");
        }
        assert_eq!(payload(&fixture.0), expected);
    }

    #[test]
    #[cfg(unix)]
    fn symlinks_cannot_bypass_hidden_file_or_directory_rules() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        fixture.write(".private/options", b"must-not-ship");
        fixture.write(&format!(".private/versions/1/contents/{OPTIONS}"), b"must-not-ship");
        let contents = fixture.0.join("versions/1/contents");
        std::fs::create_dir_all(&contents).unwrap();
        symlink(fixture.0.join(".private/options"), contents.join(OPTIONS)).unwrap();
        symlink(fixture.0.join(".private"), fixture.0.join("visible-link")).unwrap();
        assert!(payload(&fixture.0).is_empty());
    }
}
