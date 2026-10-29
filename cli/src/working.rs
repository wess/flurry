use crate::{
    disk::{self, Disk},
    model::{BYTE_LIMIT, FILES_LIMIT, Files, State},
    paths,
};
use anyhow::{Context, Result, ensure};
use cap_fs_ext::DirExt;
use cap_std::fs::Dir;
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use std::{collections::BTreeMap, io::Read, path::Path};

pub fn validate(state: &State) -> Result<()> {
    ensure!(state.version == 1, "Unsupported working-copy version");
    crate::remote::origin(&state.server)?;
    uuid::Uuid::parse_str(&state.repository)?;
    ensure!(
        state.branches.contains_key(&state.current)
            && state.branches.len() <= 1000
            && state.commits.len() <= 1000,
        "Invalid or oversized working-copy state"
    );
    if !state.prefix.is_empty() {
        paths::valid(&state.prefix)?;
    }
    let refs = state
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
    paths::manifest(&refs)?;
    for (name, branch) in &state.branches {
        paths::name(name)?;
        if let Some(head) = &branch.head {
            ensure!(state.commits.contains_key(head), "Missing head snapshot");
        }
        if let Some(head) = &branch.upstream {
            paths::hash(head)?;
        }
        if let Some(review) = &branch.review {
            uuid::Uuid::parse_str(review)?;
        }
    }
    for (id, commit) in &state.commits {
        paths::revision(id)?;
        paths::manifest(&commit.files)?;
        for hash in commit.files.values() {
            paths::hash(hash)?;
        }
        if id.len() != 64 {
            for parent in [&commit.parent, &commit.merge_parent].into_iter().flatten() {
                ensure!(
                    state.commits.contains_key(parent),
                    "Missing parent snapshot for an unpublished commit"
                );
            }
        }
        for parent in [&commit.parent, &commit.merge_parent].into_iter().flatten() {
            paths::revision(parent)?;
        }
        if !state.prefix.is_empty() {
            ensure!(
                commit
                    .files
                    .keys()
                    .all(|p| p.starts_with(&(state.prefix.clone() + "/"))),
                "Snapshot escapes sparse prefix"
            );
        }
    }
    for (path, hash) in &state.index {
        paths::valid(path)?;
        ensure!(
            state.prefix.is_empty() || path.starts_with(&(state.prefix.clone() + "/")),
            "Index escapes sparse prefix"
        );
        if let Some(hash) = hash {
            paths::hash(hash)?;
        }
    }
    for (name, id) in &state.tags {
        paths::name(name)?;
        paths::revision(id)?;
    }
    for (name, id) in &state.remotes {
        paths::name(name)?;
        if let Some(id) = id {
            paths::hash(id)?;
        }
    }
    Ok(())
}
fn rules(dir: &Dir, base: &Path) -> Result<Gitignore> {
    let mut builder = GitignoreBuilder::new(base);
    for name in [".gitignore", ".flurryignore"] {
        if dir.symlink_metadata(name).is_ok() {
            let mut text = String::new();
            disk::read(dir, name)?
                .take(65_537)
                .read_to_string(&mut text)?;
            ensure!(
                text.len() <= 65_536 && text.lines().count() <= 1000,
                "Ignore file exceeds 64 KiB or 1,000 lines"
            );
            for line in text.lines() {
                builder.add_line(None, line)?;
            }
        }
    }
    Ok(builder.build()?)
}
pub fn scan(disk: &Disk, state: &State) -> Result<Files> {
    let ignore = vec![rules(&disk.dir, &disk.root)?];
    let tracked = state.staged();
    let start = if state.prefix.is_empty() {
        disk.dir.try_clone()?
    } else {
        match disk.parent(&(state.prefix.clone() + "/placeholder"), false) {
            Ok((dir, _)) => dir,
            Err(_) if disk.dir.symlink_metadata(&state.prefix).is_err() => return Ok(Files::new()),
            Err(error) => return Err(error),
        }
    };
    let mut files = BTreeMap::new();
    let mut total = 0;
    let mut entries = 0;
    walk(
        &start,
        &state.prefix,
        &ignore,
        &disk.root,
        &tracked,
        &mut files,
        &mut total,
        &mut entries,
        0,
    )?;
    paths::manifest(&files)?;
    Ok(files)
}
#[allow(clippy::too_many_arguments)]
fn walk(
    dir: &Dir,
    prefix: &str,
    parents: &[Gitignore],
    root: &Path,
    tracked: &Files,
    files: &mut Files,
    total: &mut u64,
    entries: &mut usize,
    depth: usize,
) -> Result<()> {
    ensure!(depth <= 64, "Working directory exceeds 64 levels");
    let mut ignore = parents.to_vec();
    if !prefix.is_empty() {
        ignore.push(rules(dir, &root.join(prefix))?);
    }

    for entry in dir.entries()? {
        let entry = entry?;
        *entries += 1;
        ensure!(
            *entries <= 200_000,
            "Working directory exceeds 200,000 entries"
        );
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow::anyhow!("Non-UTF8 filename"))?;
        if [".flurry", ".git"].contains(&name.as_str()) {
            continue;
        }
        let path = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        paths::valid(&path)?;
        let kind = entry.file_type()?;
        let tracked_path = tracked.contains_key(&path)
            || tracked
                .range((path.clone() + "/")..)
                .next()
                .is_some_and(|(p, _)| p.starts_with(&(path.clone() + "/")));
        if !tracked_path
            && (["node_modules", "deps", "_build", "target", ".DS_Store"].contains(&name.as_str())
                || ignore
                    .iter()
                    .rev()
                    .map(|rule| rule.matched_path_or_any_parents(root.join(&path), kind.is_dir()))
                    .find(|matched| !matched.is_none())
                    .is_some_and(|matched| matched.is_ignore()))
        {
            continue;
        }
        ensure!(!kind.is_symlink(), "Symlinks are not supported: {path:?}");
        if kind.is_dir() {
            let child = dir.open_dir_nofollow(&name)?;
            walk(
                &child,
                &path,
                &ignore,
                root,
                tracked,
                files,
                total,
                entries,
                depth + 1,
            )?;
        } else {
            ensure!(kind.is_file(), "Non-regular file: {path:?}");
            let file = disk::read(dir, &name)?;
            let (hash, bytes) = disk::hash_reader(file, None)?;
            *total += bytes;
            ensure!(*total <= BYTE_LIMIT, "Working copy exceeds 1 GiB");
            files.insert(path, hash);
            ensure!(
                files.len() <= FILES_LIMIT,
                "Working copy exceeds 100,000 files"
            );
        }
    }
    Ok(())
}
pub fn clean(disk: &Disk, state: &State) -> Result<()> {
    ensure!(
        state.index.is_empty(),
        "Commit or unstage staged changes first"
    );
    let current = scan(disk, state)?;
    let base = state.files();
    let dirty: Vec<_> = base
        .keys()
        .filter(|p| current.get(*p) != base.get(*p))
        .collect();
    ensure!(
        dirty.is_empty(),
        "Commit or restore tracked changes first: {}",
        serde_json::to_string(&dirty)?
    );
    Ok(())
}
pub fn selection(disk: &Disk, args: &[String]) -> Result<Vec<String>> {
    let cwd = std::env::current_dir()?.canonicalize()?;
    let relative = cwd
        .strip_prefix(&disk.root)
        .context("Current directory is outside the working copy")?;
    let mut paths = Vec::new();
    for arg in args {
        let joined = relative.join(arg);
        ensure!(
            !joined.is_absolute()
                && joined.components().all(|c| matches!(
                    c,
                    std::path::Component::Normal(_) | std::path::Component::CurDir
                )),
            "Paths must stay relative to the working copy"
        );
        let text = joined
            .components()
            .filter_map(|c| match c {
                std::path::Component::Normal(s) => s.to_str(),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("/");
        if !text.is_empty() {
            paths::valid(&text)?;
        }
        paths.push(text);
    }
    Ok(paths)
}
pub fn selected(path: &str, args: &[String]) -> bool {
    args.iter()
        .any(|arg| arg.is_empty() || path == arg || path.starts_with(&(arg.clone() + "/")))
}
