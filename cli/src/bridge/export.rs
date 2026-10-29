use super::git::{git_id, object, output};
use crate::{
    disk::{self, Disk},
    model::{Branch, Commit, Files, GitData, META_LIMIT, State},
    paths,
    remote::Remote,
};
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
pub(super) fn mirror(
    disk: &Disk,
    remote: &Remote,
    repository: &str,
) -> Result<BTreeMap<String, String>> {
    output(
        &disk.root,
        &[
            "init",
            "--bare",
            "--quiet",
            "--template=",
            "--object-format=sha1",
            ".",
        ],
        None,
        4096,
    )?;
    let refs: Value = remote.get(&format!("/repositories/{repository}/refs"), &[])?;
    let mut state = State {
        version: 1,
        server: remote.origin.clone(),
        repository: repository.to_owned(),
        current: "main".into(),
        prefix: String::new(),
        branches: BTreeMap::new(),
        remotes: BTreeMap::new(),
        tags: BTreeMap::new(),
        annotations: BTreeMap::new(),
        commits: BTreeMap::new(),
        index: BTreeMap::new(),
    };
    let mut queue = VecDeque::new();
    let mut mapping = BTreeMap::new();
    let mut visited = BTreeSet::new();
    let mut known = BTreeSet::new();
    let mut blobmap = BTreeMap::new();
    let mut metadata_bytes = 0u64;
    let branches = refs["branches"].as_array().context("Invalid branch list")?;
    let tags = refs["tags"].as_array().context("Invalid tag list")?;
    ensure!(
        branches.len() + tags.len() <= 1000,
        "Git bridge supports at most 1,000 refs"
    );
    for branch in branches {
        let name = branch["name"].as_str().context("Invalid branch name")?;
        paths::name(name)?;
        let head = branch["head"].as_str().map(str::to_owned);
        if let Some(head) = &head {
            paths::hash(head)?;
            queue.push_back(head.clone());
        }
        state.branches.insert(
            name.to_owned(),
            Branch {
                head: head.clone(),
                upstream: head,
                review: None,
            },
        );
    }
    for tag in tags {
        let name = tag["name"].as_str().context("Invalid tag")?;
        paths::name(name)?;
        let target = tag["target"].as_str().context("Invalid tag target")?;
        paths::hash(target)?;
        state.tags.insert(name.to_owned(), target.to_owned());
        queue.push_back(target.to_owned());
    }
    let refnames = state
        .branches
        .keys()
        .map(|name| (format!("heads/{name}"), "0".repeat(64)))
        .chain(
            state
                .tags
                .keys()
                .map(|name| (format!("tags/{name}"), "0".repeat(64))),
        )
        .collect();
    paths::manifest(&refnames)?;
    while let Some(id) = queue.pop_front() {
        if !visited.insert(id.clone()) {
            continue;
        }
        ensure!(
            visited.len() <= 1000,
            "Git bridge supports at most 1,000 revisions per transfer"
        );
        let view: Value = remote.get(&format!("/repositories/{repository}/git/{id}"), &[])?;
        let git_id_value = view["git"].as_str().context("Missing Git identity")?;
        git_id(git_id_value)?;
        let mut files = Files::new();
        let mut modes = Files::new();
        for entry in view["files"].as_array().context("Invalid Git files")? {
            let path = entry["path"].as_str().context("Invalid Git path")?;
            paths::valid(path)?;
            let hash = entry["hash"].as_str().context("Missing content identity")?;
            paths::hash(hash)?;
            let blob = entry["git"].as_str().context("Missing Git blob identity")?;
            git_id(blob)?;
            let mode = entry["mode"].as_str().context("Missing file mode")?;
            ensure!(
                ["100644", "100755"].contains(&mode),
                "Unsupported file mode"
            );
            files.insert(path.to_owned(), hash.to_owned());
            modes.insert(path.to_owned(), mode.to_owned());
            blobmap.insert(blob.to_owned(), hash.to_owned());
            if known.insert(blob.to_owned()) {
                if disk.object(hash).is_err() {
                    let temporary = format!("download{}", uuid::Uuid::new_v4().simple());
                    let mut file = disk::create(&disk.meta, &temporary)?;
                    let result = (|| {
                        remote.download(repository, &id, path, &mut file)?;
                        drop(file);
                        disk.store(disk::read(&disk.meta, &temporary)?, Some(hash))
                    })();
                    let _ = disk.meta.remove_file(&temporary);
                    result?;
                }
                ensure!(
                    object(
                        &disk.root,
                        "blob",
                        &mut disk.object(hash)?,
                        disk.object(hash)?.metadata()?.len()
                    )? == blob,
                    "Git blob failed integrity verification"
                );
            }
        }
        paths::manifest(&files)?;
        for tree in view["trees"].as_array().context("Invalid Git trees")? {
            let expected = tree["git"].as_str().context("Invalid tree identity")?;
            git_id(expected)?;
            if known.insert(expected.to_owned()) {
                let bytes =
                    STANDARD.decode(tree["raw"].as_str().context("Missing tree object")?)?;
                ensure!(
                    object(
                        &disk.root,
                        "tree",
                        &mut bytes.as_slice(),
                        bytes.len() as u64
                    )? == expected,
                    "Git tree failed integrity verification"
                );
            }
        }
        let raw = view["raw"].as_str().context("Missing Git commit object")?;
        let bytes = STANDARD.decode(raw)?;
        ensure!(bytes.len() <= 73_728, "Git commit metadata exceeds limit");
        ensure!(
            object(
                &disk.root,
                "commit",
                &mut bytes.as_slice(),
                bytes.len() as u64
            )? == git_id_value,
            "Git commit failed integrity verification"
        );
        let parents = view["parents"].as_array().context("Invalid parents")?;
        ensure!(parents.len() <= 2, "Octopus merges are unsupported");
        for parent in parents {
            let parent = parent.as_str().context("Invalid parent")?;
            paths::hash(parent)?;
            queue.push_back(parent.to_owned());
        }
        let parent = parents.first().and_then(Value::as_str).map(str::to_owned);
        let merge_parent = parents.get(1).and_then(Value::as_str).map(str::to_owned);
        let message = String::from_utf8(bytes)?
            .split_once("\n\n")
            .map(|(_, m)| m.to_owned())
            .unwrap_or_default();
        metadata_bytes += serde_json::to_vec(&files)?.len() as u64
            + serde_json::to_vec(&modes)?.len() as u64
            + (message.len() * 6 + raw.len() + 1024) as u64;
        state.commits.insert(
            id.clone(),
            Commit {
                parent,
                merge_parent,
                message,
                files: files.into(),
                git: Some(GitData {
                    id: git_id_value.to_owned(),
                    raw: raw.to_owned(),
                    modes,
                }),
            },
        );
        ensure!(
            metadata_bytes <= META_LIMIT - 1_048_576,
            "Git mirror metadata exceeds 32 MiB"
        );
        mapping.insert(git_id_value.to_owned(), id);
    }
    for (name, branch) in &state.branches {
        if let Some(head) = &branch.head {
            let git = state.commits[head]
                .git
                .as_ref()
                .context("Missing Git mapping")?;
            output(
                &disk.root,
                &["update-ref", &format!("refs/heads/{name}"), &git.id],
                None,
                4096,
            )?;
        }
    }
    for tag in tags {
        let name = tag["name"].as_str().context("Invalid tag name")?;
        let target = tag["target"].as_str().context("Invalid tag target")?;
        let commit = state.commits[target]
            .git
            .as_ref()
            .context("Missing tag mapping")?;
        let reference = if let Some(raw) = tag["raw"].as_str() {
            let bytes = STANDARD.decode(raw)?;
            let id = tag["git"]
                .as_str()
                .context("Missing annotated tag identity")?;
            git_id(id)?;
            ensure!(
                object(&disk.root, "tag", &mut bytes.as_slice(), bytes.len() as u64)? == id,
                "Tag integrity verification failed"
            );
            id
        } else {
            &commit.id
        };
        output(
            &disk.root,
            &["update-ref", &format!("refs/tags/{name}"), reference],
            None,
            4096,
        )?;
    }
    output(
        &disk.root,
        &["symbolic-ref", "HEAD", "refs/heads/main"],
        None,
        4096,
    )?;
    disk.save_state(&state)?;
    disk.save("mapping.json", &mapping)?;
    disk.save("blobmap.json", &blobmap)?;
    Ok(mapping)
}
