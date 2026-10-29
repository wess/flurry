use fsc::{
    disk::{self, Disk},
    journal,
    model::{Branch, Commit, Files, State, merge},
    paths,
};
use std::collections::BTreeMap;
fn state() -> State {
    State {
        version: 1,
        server: "http://127.0.0.1:4040".into(),
        repository: uuid::Uuid::new_v4().to_string(),
        current: "main".into(),
        prefix: String::new(),
        branches: BTreeMap::from([(
            "main".into(),
            Branch {
                head: None,
                upstream: None,
                review: None,
            },
        )]),
        remotes: BTreeMap::new(),
        tags: BTreeMap::new(),
        annotations: BTreeMap::new(),
        commits: BTreeMap::new(),
        index: BTreeMap::new(),
    }
}
#[test]
fn rejects_unsafe_and_nonportable_paths() {
    for path in [
        "../escape",
        "/absolute",
        "a/../b",
        "a\\b",
        ".git/config",
        "src/.flurry/state.json",
        "NUL",
        "a.",
        "a/",
        "a\nfile",
        "x\u{202e}txt",
    ] {
        assert!(paths::valid(path).is_err(), "{path:?}");
    }
    assert!(paths::valid("src/lib.rs").is_ok());
}
#[test]
fn rejects_case_unicode_and_directory_aliases() {
    for names in [["src/a", "SRC/b"], ["a", "a/b"], ["é/a", "e\u{301}/b"]] {
        let files = names
            .into_iter()
            .map(|s| (s.to_string(), "x".repeat(64)))
            .collect();
        assert!(paths::manifest(&files).is_err());
    }
}
#[test]
fn merges_disjoint_edits_and_rejects_conflicts_and_delete_modify() {
    let files = |pairs: &[(&str, &str)]| {
        pairs
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect::<Files>()
    };
    let base = files(&[("a", "1"), ("b", "1")]);
    let left = files(&[("a", "2"), ("b", "1")]);
    let right = files(&[("a", "1"), ("b", "2")]);
    assert_eq!(
        merge(&base, &left, &right).unwrap(),
        files(&[("a", "2"), ("b", "2")])
    );
    assert!(merge(&base, &left, &Files::new()).is_err());
    assert_eq!(merge(&base, &left, &left).unwrap(), left);
}
#[test]
fn hashes_streamed_content_in_the_server_domain() {
    let (hash, size) = disk::hash_reader("hello".as_bytes(), None).unwrap();
    use sha2::{Digest, Sha256};
    assert_eq!(hash, hex::encode(Sha256::digest(b"blob\0hello")));
    assert_eq!(size, 5);
}
#[test]
fn concurrent_commands_fail_without_touching_working_copy() {
    let root = tempfile::tempdir().unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    assert!(Disk::open(root.path(), false).is_err());
    drop(disk);
    assert!(Disk::open(root.path(), false).is_ok());
}
#[test]
fn journal_completes_and_is_idempotent_after_a_crash() {
    let root = tempfile::tempdir().unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    let mut state = state();
    disk.save("state.json", &state).unwrap();
    let (hash, _) = disk.store("new".as_bytes(), None).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    state.commits.insert(
        id.clone(),
        Commit {
            parent: None,
            merge_parent: None,
            message: "new".into(),
            files: BTreeMap::from([("a".into(), hash.clone())]).into(),
            git: None,
        },
    );
    state.branches.get_mut("main").unwrap().head = Some(id);
    let temporary = format!(".fsctmp{}", uuid::Uuid::new_v4().simple());
    std::fs::write(root.path().join(&temporary), b"partial").unwrap();
    disk.save(
        "transaction.json",
        &serde_json::json!({"state":state,"operations":[{"path":"a","before":null,"after":hash,"temporary":temporary}]}),
    )
    .unwrap();
    journal::recover(&disk).unwrap();
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"new");
    assert!(disk.meta.symlink_metadata("transaction.json").is_err());
    assert!(!root.path().join(temporary).exists());
}
#[test]
fn journal_preserves_edits_made_after_interruption() {
    let root = tempfile::tempdir().unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    let state = state();
    let (hash, _) = disk.store("remote".as_bytes(), None).unwrap();
    disk.save(
        "transaction.json",
        &serde_json::json!({"state":state,"operations":[{"path":"a","before":null,"after":hash}]}),
    )
    .unwrap();
    std::fs::write(root.path().join("a"), b"precious").unwrap();
    assert!(journal::recover(&disk).is_err());
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"precious");
}
#[test]
fn checkout_preflight_preserves_untracked_files() {
    let root = tempfile::tempdir().unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    let (hash, _) = disk.store("remote".as_bytes(), None).unwrap();
    std::fs::write(root.path().join("a"), b"precious").unwrap();
    assert!(
        journal::apply(
            &disk,
            &Files::new(),
            &BTreeMap::from([("a".into(), hash)]),
            state()
        )
        .is_err()
    );
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"precious");
    assert!(disk.meta.symlink_metadata("transaction.json").is_err());
}
#[cfg(unix)]
#[test]
fn symlinked_files_parents_metadata_and_cache_cannot_escape() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret"), b"secret").unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    symlink(outside.path(), root.path().join("escape")).unwrap();
    assert!(disk.file("escape/secret").is_err());
    symlink(outside.path().join("secret"), root.path().join("link")).unwrap();
    assert!(disk.file("link").is_err());
    assert!(fsc::working::scan(&disk, &state()).is_err());
    let fake = "a".repeat(64);
    symlink(
        outside.path().join("secret"),
        root.path().join(".flurry/objects").join(&fake),
    )
    .unwrap();
    assert!(disk.object(&fake).is_err());
    drop(disk);
    let other = tempfile::tempdir().unwrap();
    symlink(outside.path(), other.path().join(".flurry")).unwrap();
    assert!(Disk::open(other.path(), false).is_err());
}
#[test]
fn invalid_origins_cannot_receive_credentials() {
    for url in [
        "http://example.com",
        "https://user:pass@example.com",
        "https://example.com/path",
        "https://example.com?token=x",
        "file:///tmp/x",
    ] {
        assert!(fsc::remote::origin(url).is_err());
    }
    assert_eq!(
        fsc::remote::origin("https://EXAMPLE.com:443/").unwrap(),
        "https://example.com"
    );
}

#[test]
fn gitignore_and_flurryignore_are_scoped_and_do_not_hide_tracked_files() {
    let root = tempfile::tempdir().unwrap();
    let disk = Disk::open(root.path(), true).unwrap();
    let mut state = state();
    std::fs::write(root.path().join(".gitignore"), "*.secret\n").unwrap();
    std::fs::write(root.path().join("private.secret"), "private").unwrap();
    std::fs::create_dir(root.path().join("src")).unwrap();
    std::fs::write(root.path().join("src/.gitignore"), "local\n").unwrap();
    std::fs::write(root.path().join("src/local"), "local").unwrap();
    std::fs::write(root.path().join("local"), "keep").unwrap();
    let files = fsc::working::scan(&disk, &state).unwrap();
    assert!(!files.contains_key("private.secret"));
    assert!(!files.contains_key("src/local"));
    assert!(files.contains_key("local"));
    let (hash, _) = disk.store("private".as_bytes(), None).unwrap();
    state.index.insert("private.secret".into(), Some(hash));
    assert!(
        fsc::working::scan(&disk, &state)
            .unwrap()
            .contains_key("private.secret")
    );
}
#[test]
#[ignore = "requires access to the local OS credential store"]
fn native_credential_store_roundtrip() {
    let name = format!("https://fixture{}.invalid", uuid::Uuid::new_v4().simple());
    let entry = keyring::Entry::new("flurry.fsc.test", &name).unwrap();
    entry.set_password("synthetic-test-credential").unwrap();
    let result = entry.get_password();
    entry.delete_credential().unwrap();
    assert_eq!(result.unwrap(), "synthetic-test-credential");
    assert!(matches!(entry.get_password(), Err(keyring::Error::NoEntry)));
}

#[test]
fn three_way_text_merge_preserves_disjoint_line_edits_and_refuses_overlap() {
    assert_eq!(
        fsc::merge::text(
            "one\ntwo\nthree\n",
            "ONE\ntwo\nthree\n",
            "one\ntwo\nTHREE\n"
        )
        .unwrap(),
        "ONE\ntwo\nTHREE\n"
    );
    assert!(fsc::merge::text("one\n", "left\n", "right\n").is_err());
    assert_eq!(fsc::merge::text("", "same\n", "same\n").unwrap(), "same\n");
    assert!(fsc::merge::text("", "left\n", "right\n").is_err());
    assert_eq!(
        fsc::merge::text("one\ntwo\n", "ONE\ntwo\n", "one\nTWO\n").unwrap(),
        "ONE\nTWO\n"
    );
}
