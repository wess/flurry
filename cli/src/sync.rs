use crate::{
    args::{Args, Command, Review, Source},
    commands::remote,
    disk::Disk,
    graph, journal,
    model::State,
    paths, push, snapshot, working,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
pub(crate) fn run(args: &Args, disk: &Disk, state: &mut State) -> Result<Option<Value>> {
    let value = match &args.command {
        Command::Fetch => {
            let client = remote(args, Some(state))?;
            snapshot::fetch(disk, state, &client)?;
            disk.save_state(state)?;
            json!({"remotes":state.remotes,"tags":state.tags})
        }
        Command::Pull { .. } => {
            working::clean(disk, state)?;
            let remote = remote(args, Some(state))?;
            let before = state.files();
            snapshot::fetch(disk, state, &remote)?;
            let target = state
                .remotes
                .get(&state.current)
                .context("Branch has no remote; push it first")?
                .clone();
            let branch = &state.branches[&state.current];
            if target != branch.upstream || target == branch.head {
                let common = graph::base(state, &remote, state.head(), target.as_deref())?;
                ensure!(
                    common.as_deref() == state.head() || common == target,
                    "Local and remote history diverged; fetch, then merge origin/<branch>"
                );
                let branch = state
                    .branches
                    .get_mut(&state.current)
                    .context("Missing branch")?;
                if common == branch.head {
                    branch.head = target.clone();
                }
                branch.upstream = target;
                branch.review = None;
                journal::apply(disk, &before, &state.files(), state.clone())?;
            } else {
                disk.save_state(state)?;
            }
            json!({"branch":state.current,"head":state.head(),"pending_review":state.branches[&state.current].review})
        }
        Command::Push { tags, abort } => {
            let client = remote(args, Some(state))?;
            if *abort {
                push::abort(disk, state, &client)?
            } else {
                push::push(disk, state, &client, *tags)?
            }
        }
        Command::Review { command } => {
            let remote = remote(args, Some(state))?;
            let prefix = format!("/repositories/{}/reviews", state.repository);
            match command {
                Review::List => remote.get(&prefix, &[])?,
                Review::Show { id } => {
                    uuid::Uuid::parse_str(id)?;
                    remote.get(&format!("{prefix}/{id}"), &[])?
                }
                Review::Approve { id } | Review::Land { id } => {
                    uuid::Uuid::parse_str(id)?;
                    let operation = if matches!(command, Review::Approve { .. }) {
                        "approve"
                    } else {
                        "land"
                    };
                    remote.post(&format!("{prefix}/{id}/{operation}"), &json!({}))?
                }
                Review::Comment { id, message } => {
                    uuid::Uuid::parse_str(id)?;
                    remote.post(&format!("{prefix}/{id}/comments"), &json!({"body":message}))?
                }
            }
        }
        Command::Source { command } => {
            let remote = remote(args, Some(state))?;
            let prefix = format!("/repositories/{}/source", state.repository);
            match command {
                Source::Status => remote.get(&prefix, &[])?,
                Source::Pull {
                    token_stdin,
                    username,
                }
                | Source::Push {
                    token_stdin,
                    username,
                    ..
                } => {
                    let token = if *token_stdin {
                        Some(crate::auth::stdin_secret()?)
                    } else {
                        None
                    };
                    let head = if let Source::Push { revision, .. } = command {
                        paths::hash(revision)?;
                        Some(revision)
                    } else {
                        None
                    };
                    remote.post(&format!("{prefix}/{}", if head.is_some() {"push"} else {"pull"}), &json!({"head":head,"token":token.as_ref().map(|s|s.as_str()),"username":username}))?
                }
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(value))
}
