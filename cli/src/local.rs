use crate::{
    args::{Args, Command},
    commands::local_commit,
    disk::Disk,
    journal,
    model::{State, delta},
    working,
};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::collections::BTreeSet;
pub(crate) fn run(args: &Args, disk: &Disk, state: &mut State) -> Result<Option<Value>> {
    let value = match &args.command {
        Command::Status => {
            let current = working::scan(disk, state)?;
            let base = state.files();
            let index = state.staged();
            let staged = delta(&base, &index);
            let mut unstaged = delta(&index, &current);
            unstaged.retain(|path, _| index.contains_key(path));
            let untracked: Vec<_> = current
                .keys()
                .filter(|path| !index.contains_key(*path))
                .cloned()
                .collect();
            if !args.json {
                println!("On branch {}", state.current);
                if let Some(head) = state.head() {
                    println!("HEAD {}", &head[..8]);
                }
                for (path, hash) in &staged {
                    println!(
                        "{}  {:?}",
                        if hash.is_none() {
                            "D"
                        } else if base.contains_key(path) {
                            "M"
                        } else {
                            "A"
                        },
                        path
                    );
                }
                for (path, hash) in &unstaged {
                    println!(" {} {:?}", if hash.is_none() { "D" } else { "M" }, path);
                }
                for path in &untracked {
                    println!("?? {:?}", path);
                }
                if staged.is_empty() && unstaged.is_empty() && untracked.is_empty() {
                    println!("Working copy clean");
                }
                if let Some(review) = &state.branches[&state.current].review {
                    println!("Pending review {review}");
                }
                if disk.meta.symlink_metadata("push.json").is_ok() {
                    println!(
                        "Pending push: rerun fsc push, or fsc push --abort to check its receipt"
                    );
                }
                return Ok(Some(Value::Null));
            }
            json!({"branch":state.current,"head":state.head(),"staged":staged,"unstaged":unstaged,"untracked":untracked,"pending_review":state.branches[&state.current].review,"pending_push":disk.meta.symlink_metadata("push.json").is_ok()})
        }
        Command::Add { paths: input, all } => {
            let selected = if *all {
                vec![String::new()]
            } else {
                working::selection(disk, input)?
            };
            let current = working::scan(disk, state)?;
            let base = state.files();
            let candidates: BTreeSet<_> = current
                .keys()
                .chain(base.keys())
                .chain(state.index.keys())
                .filter(|path| working::selected(path, &selected))
                .cloned()
                .collect();
            ensure!(!candidates.is_empty(), "No matching files");
            for path in candidates {
                let value = if let Some(expected) = current.get(&path) {
                    Some(disk.store(disk.file(&path)?, Some(expected))?.0)
                } else {
                    None
                };
                if value.as_ref() == base.get(&path) {
                    state.index.remove(&path);
                } else {
                    state.index.insert(path, value);
                }
            }
            disk.save_state(state)?;
            json!({"staged":state.index})
        }
        Command::Commit { message, amend } => {
            let files = state.staged();
            let original = if *amend {
                let head = state
                    .head()
                    .ok_or_else(|| anyhow::anyhow!("No commit to amend"))?;
                ensure!(
                    head.len() != 64,
                    "Published commits are immutable; create a new commit"
                );
                Some(state.commits[head].clone())
            } else {
                None
            };
            let id = if let Some(old) = &original {
                ensure!(
                    !message.trim().is_empty() && message.len() <= 2000,
                    "Commit message must be 1-2,000 bytes"
                );
                let id = uuid::Uuid::new_v4().to_string();
                crate::paths::manifest(&files)?;
                let parent_files = old
                    .parent
                    .as_ref()
                    .map(|id| state.commits[id].files.clone())
                    .unwrap_or_default();
                ensure!(
                    delta(&parent_files, &files).len() <= 100,
                    "A commit may change at most 100 files"
                );
                state.commits.insert(
                    id.clone(),
                    crate::model::Commit {
                        parent: old.parent.clone(),
                        merge_parent: old.merge_parent.clone(),
                        message: message.clone(),
                        files: files.into(),
                        git: None,
                    },
                );
                state
                    .branches
                    .get_mut(&state.current)
                    .ok_or_else(|| anyhow::anyhow!("Missing branch"))?
                    .head = Some(id.clone());
                state.index.clear();
                id
            } else {
                local_commit(state, message, None, files)?
            };
            working::validate(state)?;
            disk.save_state(state)?;
            json!({"commit":id,"branch":state.current,"message":message})
        }
        Command::Restore {
            staged,
            paths: input,
        } => {
            let selected = working::selection(disk, input)?;
            if *staged {
                state
                    .index
                    .retain(|path, _| !working::selected(path, &selected));
                disk.save_state(state)?;
            } else {
                let actual = working::scan(disk, state)?;
                let target = state.staged();
                let mut next = actual.clone();
                let base = state.files();
                let candidates: BTreeSet<_> = base
                    .keys()
                    .chain(target.keys())
                    .filter(|p| working::selected(p, &selected))
                    .cloned()
                    .collect();
                ensure!(
                    !candidates.is_empty(),
                    "No tracked paths matched; untracked files are preserved"
                );
                for path in &candidates {
                    if let Some(hash) = target.get(path) {
                        next.insert(path.clone(), hash.clone());
                    } else {
                        next.remove(path);
                    }
                }
                journal::apply(disk, &actual, &next, state.clone())?;
            }
            json!({"restored":selected,"staged":staged})
        }
        Command::Gc => {
            let used: BTreeSet<_> = state
                .commits
                .values()
                .flat_map(|c| c.files.values())
                .chain(state.index.values().flatten())
                .cloned()
                .collect();
            let mut bytes = 0;
            let mut removed = 0;
            for entry in disk.objects.entries()? {
                let entry = entry?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("Invalid cache entry"))?;
                ensure!(
                    entry.file_type()?.is_file(),
                    "Cache contains a symlink or directory"
                );
                if !used.contains(&name) {
                    bytes += entry.metadata()?.len();
                    disk.objects.remove_file(&name)?;
                    removed += 1;
                }
            }
            crate::disk::sync(&disk.objects)?;
            json!({"removed":removed,"bytes":bytes})
        }
        Command::Remote => {
            json!({"server":state.server,"repository":state.repository,"branch":state.current})
        }
        _ => return Ok(None),
    };
    Ok(Some(value))
}
