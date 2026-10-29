use crate::{
    args::{Args, Command},
    commands::{local_commit, remote, resolve},
    disk::Disk,
    graph, journal,
    model::{Branch, State},
    paths, snapshot, working,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
pub(crate) fn run(args: &Args, disk: &Disk, state: &mut State) -> Result<Option<Value>> {
    let value = match &args.command {
        Command::Branch {
            name,
            start,
            delete,
        } => {
            if let Some(name) = name {
                paths::name(name)?;
                if *delete {
                    ensure!(*name != state.current, "Cannot delete the current branch");
                    let branch = state.branches.get(name).context("Branch not found")?;
                    ensure!(
                        graph::base(
                            state,
                            &remote(args, Some(state))?,
                            branch.head.as_deref(),
                            state.head()
                        )? == branch.head,
                        "Branch is not merged; preserve its commits before deleting"
                    );
                    state.branches.remove(name);
                } else {
                    ensure!(!state.branches.contains_key(name), "Branch already exists");
                    let head = resolve(state, start.as_deref().unwrap_or("HEAD"))?;
                    if let Some(id) = &head
                        && !state.commits.contains_key(id)
                    {
                        let client = remote(args, Some(state))?;
                        snapshot::capture(disk, state, &client, Some(id))?;
                    }
                    state.branches.insert(
                        name.clone(),
                        Branch {
                            head,
                            upstream: None,
                            review: None,
                        },
                    );
                }
                disk.save_state(state)?;
            }
            json!({"current":state.current,"branches":state.branches,"remotes":state.remotes})
        }
        Command::Switch { name, create } => {
            working::clean(disk, state)?;
            paths::name(name)?;
            let before = state.files();
            if *create {
                ensure!(!state.branches.contains_key(name), "Branch already exists");
                state.branches.insert(
                    name.clone(),
                    Branch {
                        head: state.head().map(str::to_owned),
                        upstream: None,
                        review: None,
                    },
                );
            }
            if !state.branches.contains_key(name) {
                let head = state
                    .remotes
                    .get(name)
                    .context("Unknown branch; use --create or fetch first")?
                    .clone();
                let client = remote(args, Some(state))?;
                snapshot::capture(disk, state, &client, head.as_deref())?;
                state.branches.insert(
                    name.clone(),
                    Branch {
                        head: head.clone(),
                        upstream: head,
                        review: None,
                    },
                );
            }
            state.current = name.clone();
            journal::apply(disk, &before, &state.files(), state.clone())?;
            json!({"branch":state.current,"head":state.head()})
        }
        Command::Tag {
            name,
            target,
            delete,
            annotated: _,
            message,
        } => {
            if let Some(name) = name {
                paths::name(name)?;
                if *delete {
                    ensure!(state.tags.remove(name).is_some(), "Local tag not found");
                    state.annotations.remove(name);
                } else {
                    ensure!(!state.tags.contains_key(name), "Tag already exists");
                    let id = resolve(state, target.as_deref().unwrap_or("HEAD"))?
                        .context("Cannot tag an empty repository")?;
                    state.tags.insert(name.clone(), id);
                    if let Some(message) = message {
                        ensure!(
                            !message.trim().is_empty() && message.len() <= 10_000,
                            "Tag message must be 1-10,000 bytes"
                        );
                        state.annotations.insert(name.clone(), message.clone());
                    }
                }
                disk.save_state(state)?;
            }
            json!({"tags":state.tags})
        }
        Command::Merge { revision, message } => {
            ensure!(
                state.prefix.is_empty(),
                "Merge requires a full checkout; sparse working copies cannot construct complete merge trees"
            );
            working::clean(disk, state)?;
            let remote = remote(args, Some(state))?;
            let target = resolve(state, revision)?;
            if let Some(id) = &target
                && !state.commits.contains_key(id)
            {
                snapshot::capture(disk, state, &remote, Some(id))?;
            }
            let base = graph::base(state, &remote, state.head(), target.as_deref())?;
            if base == target {
                json!({"status":"already merged"})
            } else {
                let before = state.files();
                let theirs = target
                    .as_ref()
                    .map(|id| state.commits[id].files.clone())
                    .unwrap_or_default();
                if base.as_deref() == state.head() {
                    state
                        .branches
                        .get_mut(&state.current)
                        .context("Missing branch")?
                        .head = target;
                } else {
                    if let Some(id) = &base
                        && !state.commits.contains_key(id)
                    {
                        snapshot::capture(disk, state, &remote, Some(id))?;
                    }
                    let original = base
                        .as_ref()
                        .map(|id| state.commits[id].files.clone())
                        .unwrap_or_default();
                    let files = crate::merge::files(disk, &original, &before, &theirs)?;
                    local_commit(
                        state,
                        message.as_deref().unwrap_or(&format!("Merge {revision}")),
                        target,
                        files,
                    )?;
                }
                journal::apply(disk, &before, &state.files(), state.clone())?;
                json!({"head":state.head(),"branch":state.current})
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(value))
}
