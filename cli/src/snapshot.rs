use crate::{
    disk::{self, Disk},
    model::{BYTE_LIMIT, Commit, FILES_LIMIT, Files, State},
    paths,
    remote::Remote,
};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
struct Tree {
    revision: Option<String>,
    entries: Vec<Entry>,
}
#[derive(Deserialize)]
struct Entry {
    name: String,
    r#type: String,
    hash: String,
}
pub fn capture(
    disk: &Disk,
    state: &mut State,
    remote: &Remote,
    id: Option<&str>,
) -> Result<Option<String>> {
    let Some(id) = id else { return Ok(None) };
    paths::hash(id)?;
    if state.commits.contains_key(id) {
        return Ok(Some(id.to_owned()));
    }
    ensure!(
        state.commits.len() < 1000,
        "Snapshot cache is full; use a fresh clone"
    );
    let metadata: Value = remote.get(
        &format!("/repositories/{}/changesets/{id}", state.repository),
        &[],
    )?;
    ensure!(
        metadata["changeset"]["id"].as_str() == Some(id),
        "Server returned a different revision"
    );
    let parent = metadata["changeset"]["parent"].as_str().map(str::to_owned);
    let merge_parent = metadata["changeset"]["merge_parent"]
        .as_str()
        .map(str::to_owned);
    let message = metadata["changeset"]["message"]
        .as_str()
        .unwrap_or("")
        .to_string();
    let mut files = Files::new();
    let mut directories = vec![state.prefix.clone()];
    let mut seen = BTreeSet::new();
    let mut count = 0;
    while let Some(directory) = directories.pop() {
        ensure!(seen.insert(directory.clone()), "Repeated server directory");
        let tree: Tree = remote.get(
            &format!("/repositories/{}/tree", state.repository),
            &[("path", &directory), ("revision", id)],
        )?;
        ensure!(
            tree.revision.as_deref() == Some(id),
            "Server tree revision mismatch"
        );
        for entry in tree.entries {
            count += 1;
            ensure!(count <= FILES_LIMIT * 2, "Server tree exceeds entry limit");
            ensure!(!entry.name.contains('/'), "Invalid server entry name");
            let path = if directory.is_empty() {
                entry.name
            } else {
                format!("{directory}/{}", entry.name)
            };
            paths::valid(&path)?;
            paths::hash(&entry.hash)?;
            match entry.r#type.as_str() {
                "tree" => directories.push(path),
                "blob" => {
                    ensure!(
                        files.insert(path, entry.hash).is_none(),
                        "Duplicate server file"
                    );
                }
                _ => anyhow::bail!("Unknown server entry type"),
            }
        }
    }
    paths::manifest(&files)?;
    let mut total = 0;
    for (path, hash) in &files {
        if disk.objects.symlink_metadata(hash).is_ok() {
            disk.verify(hash)?;
            total += disk.object(hash)?.metadata()?.len();
        } else {
            let temporary = format!("download{}", uuid::Uuid::new_v4().simple());
            let mut file = disk::create(&disk.meta, &temporary)?;
            let result = (|| {
                remote.download(&state.repository, id, path, &mut file)?;
                drop(file);
                disk.store(disk::read(&disk.meta, &temporary)?, Some(hash))
            })();
            let _ = disk.meta.remove_file(&temporary);
            total += result?.1;
        }
        ensure!(total <= BYTE_LIMIT, "Checkout exceeds 1 GiB");
    }
    state.commits.insert(
        id.to_owned(),
        Commit {
            parent,
            merge_parent,
            message,
            files: files.into(),
            git: None,
        },
    );
    Ok(Some(id.to_owned()))
}
pub fn fetch(disk: &Disk, state: &mut State, remote: &Remote) -> Result<()> {
    let refs: Value = remote.get(&format!("/repositories/{}/refs", state.repository), &[])?;
    let branches = refs["branches"]
        .as_array()
        .context("Invalid refs response")?;
    ensure!(branches.len() <= 1000, "Too many remote branches");
    let mut remotes = BTreeMap::new();
    for branch in branches {
        let name = branch["name"].as_str().context("Invalid branch name")?;
        paths::name(name)?;
        let head = branch["head"].as_str().map(str::to_owned);
        if let Some(head) = &head {
            paths::hash(head)?;
        }
        remotes.insert(name.to_owned(), head);
    }
    state.remotes = remotes;
    // tags are fetched as names and targets; their contents are downloaded on switch/merge
    if let Some(tags) = refs["tags"].as_array() {
        ensure!(tags.len() <= 10_000, "Too many remote tags");
        for tag in tags {
            let name = tag["name"].as_str().context("Invalid tag name")?;
            paths::name(name)?;
            let target = tag["target"].as_str().context("Invalid tag target")?;
            paths::hash(target)?;
            if let Some(message) = tag["message"].as_str() {
                state
                    .annotations
                    .insert(name.to_owned(), message.to_owned());
            }
            if let Some(local) = state.tags.get(name) {
                ensure!(
                    local == target,
                    "Remote tag disagrees with local tag {name:?}"
                );
            } else {
                state.tags.insert(name.to_owned(), target.to_owned());
            }
        }
    }
    if let Some(review) = state.branches[&state.current].review.clone() {
        let status: Value = remote.get(
            &format!("/repositories/{}/reviews/{review}", state.repository),
            &[],
        )?;
        if status["status"].as_str() == Some("landed") {
            state
                .branches
                .get_mut(&state.current)
                .context("Missing branch")?
                .review = None;
        }
    }
    if let Some(head) = state.remotes.get(&state.current).cloned().flatten() {
        capture(disk, state, remote, Some(&head))?;
    }
    Ok(())
}
