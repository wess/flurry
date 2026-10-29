use super::{
    client,
    git::{Batch, git_id, output},
    line,
};
use crate::{
    disk::Disk,
    model::{Branch, Commit, Files, GitData, META_LIMIT, State},
    paths,
};
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};
pub(super) fn hook(root: &Path) -> Result<()> {
    std::fs::create_dir_all(root.join("hooks"))?;
    let path = root.join("hooks/pre-receive");
    std::fs::write(&path, b"#!/bin/sh\nexec \"$FSC_HELPER\" --receive\n")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
pub(super) fn run() -> Result<()> {
    let root =
        PathBuf::from(std::env::var_os("FSC_BRIDGE_ROOT").context("Missing bridge context")?);
    let server = std::env::var("FSC_SERVER")?;
    let remote = client(&server)?;
    let disk = Disk::open(&root, false)?;
    let mut state: State = disk.load("state.json")?;
    let mut mapping: BTreeMap<String, String> = disk.load("mapping.json")?;
    let mut blobmap: BTreeMap<String, String> = disk.load("blobmap.json")?;
    let mut batch = Batch::new(&root)?;
    let mut input = std::io::stdin();
    let mut updates = Vec::new();
    while let Some(line) = line(&mut input)? {
        updates.push(line);
        ensure!(
            updates.len() <= 1,
            "Push one branch or tag at a time; atomic multi-ref push is not implemented"
        );
    }
    let parts: Vec<_> = updates.first().context("Empty push")?.split(' ').collect();
    ensure!(parts.len() == 3, "Invalid ref update");
    let (old, new, reference) = (parts[0], parts[1], parts[2]);
    git_id(old)?;
    git_id(new)?;
    ensure!(
        new != "0000000000000000000000000000000000000000",
        "Remote deletion is not supported; published tags are immutable"
    );
    if let Some(tag) = reference.strip_prefix("refs/tags/") {
        paths::name(tag)?;
        let kind = output(&root, &["cat-file", "-t", new], None, 128)?;
        let (target, annotation, message) = if kind.starts_with(b"tag") {
            let raw = output(&root, &["cat-file", "tag", new], None, 73_728)?;
            let text = std::str::from_utf8(&raw).context("Tag annotations must be UTF-8")?;
            let (headers, message) = text.split_once("\n\n").context("Invalid tag annotation")?;
            let target = headers
                .lines()
                .find_map(|line| line.strip_prefix("object "))
                .context("Missing tag target")?;
            let target = mapping
                .get(target)
                .context("Push the branch before its tag; nested tags are unsupported")?
                .clone();
            (
                target,
                Some(json!({"id":new,"raw":STANDARD.encode(&raw)})),
                Some(message.trim().to_owned()),
            )
        } else {
            (
                mapping
                    .get(new)
                    .context("Push the branch before its tag")?
                    .clone(),
                None,
                None,
            )
        };
        let _: Value = remote.post(
            &format!("/repositories/{}/tags", state.repository),
            &json!({"name":tag,"target":target,"git":annotation,"message":message}),
        )?;
        return Ok(());
    }
    let branch = reference
        .strip_prefix("refs/heads/")
        .context("Only branch and tag refs are supported")?;
    paths::name(branch)?;
    let expected = if old.bytes().all(|b| b == b'0') {
        None
    } else {
        Some(mapping.get(old).context("Unknown remote base")?.clone())
    };
    if !state.branches.contains_key(branch) {
        state.branches.insert(
            branch.to_owned(),
            Branch {
                head: expected.clone(),
                upstream: expected.clone(),
                review: None,
            },
        );
    }
    state.current = branch.to_owned();
    let revs = output(
        &root,
        &[
            "rev-list",
            "--reverse",
            "--topo-order",
            "--max-count=101",
            new,
            "--not",
            "--all",
        ],
        None,
        16_384,
    )?;
    let revs = std::str::from_utf8(&revs)?.lines().collect::<Vec<_>>();
    ensure!(revs.len() <= 100, "Push at most 100 Git commits at a time");
    for id in revs {
        git_id(id)?;
        let raw = output(&root, &["cat-file", "commit", id], None, 73_728)?;
        let text = std::str::from_utf8(&raw).context("Git commit messages must be UTF-8")?;
        let (headers, message) = text.split_once("\n\n").context("Invalid Git commit")?;
        let parents = headers
            .lines()
            .filter_map(|line| line.strip_prefix("parent "))
            .collect::<Vec<_>>();
        ensure!(parents.len() <= 2, "Octopus merges are not supported");
        let parent = parents
            .first()
            .map(|id| {
                mapping
                    .get(*id)
                    .cloned()
                    .context("Missing first parent mapping")
            })
            .transpose()?;
        let merge_parent = parents
            .get(1)
            .map(|id| {
                mapping
                    .get(*id)
                    .cloned()
                    .context("Missing merge parent mapping")
            })
            .transpose()?;
        let tree = output(&root, &["ls-tree", "-r", "-z", id], None, META_LIMIT)?;
        let mut files = Files::new();
        let mut modes = Files::new();
        for entry in tree.split(|b| *b == 0).filter(|e| !e.is_empty()) {
            let entry = std::str::from_utf8(entry)?;
            let (metadata, path) = entry.split_once('\t').context("Invalid Git tree entry")?;
            paths::valid(path)?;
            let fields = metadata.split(' ').collect::<Vec<_>>();
            ensure!(
                fields.len() == 3
                    && fields[1] == "blob"
                    && ["100644", "100755"].contains(&fields[0]),
                "Symlinks and submodules are not supported"
            );
            git_id(fields[2])?;
            let hash = if let Some(hash) = blobmap.get(fields[2]) {
                hash.clone()
            } else {
                let hash = batch.blob(fields[2], &disk)?;
                blobmap.insert(fields[2].to_owned(), hash.clone());
                hash
            };
            ensure!(
                files.len() < crate::model::FILES_LIMIT,
                "Git tree exceeds 100,000 files"
            );
            files.insert(path.to_owned(), hash);
            modes.insert(path.to_owned(), fields[0].to_owned());
        }
        paths::manifest(&files)?;
        let native = uuid::Uuid::new_v4().to_string();
        state.commits.insert(
            native.clone(),
            Commit {
                parent,
                merge_parent,
                message: message.trim_end_matches('\n').to_owned(),
                files: files.into(),
                git: Some(GitData {
                    id: id.to_owned(),
                    raw: STANDARD.encode(&raw),
                    modes,
                }),
            },
        );
        mapping.insert(id.to_owned(), native);
    }
    let tip = mapping
        .get(new)
        .context("Missing new commit mapping")?
        .clone();
    state
        .branches
        .get_mut(branch)
        .context("Missing push branch")?
        .head = Some(tip);
    state
        .branches
        .get_mut(branch)
        .context("Missing push branch")?
        .upstream = expected;
    disk.save_state(&state)?;
    let result = crate::push::push(&disk, &mut state, &remote, false)?;
    if branch == "main" && result["review_id"].is_string() {
        bail!(
            "main is protected. Flurry created review {}. Approve and land it with fsc or the web UI, then fetch again. Topic branches can be pushed directly.",
            result["review_id"]
        );
    }
    eprintln!("Flurry accepted {reference}");
    Ok(())
}
