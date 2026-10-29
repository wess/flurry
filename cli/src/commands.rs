use crate::{
    args::{Args, Command},
    disk::Disk,
    journal,
    model::{Branch, Commit, Files, State, delta},
    paths, push,
    remote::Remote,
    working,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::collections::BTreeMap;
pub(crate) fn server(args: &Args, state: Option<&State>) -> Result<String> {
    let server = crate::remote::origin(
        args.server
            .as_deref()
            .or(state.map(|s| s.server.as_str()))
            .unwrap_or("http://127.0.0.1:4040"),
    )?;
    if let Some(state) = state {
        ensure!(
            server == state.server,
            "Server does not match this working copy"
        );
    }
    Ok(server)
}
pub(crate) fn remote(args: &Args, state: Option<&State>) -> Result<Remote> {
    let server = server(args, state)?;
    Remote::new(&server, crate::auth::token(&server, args.server.is_some())?)
}
pub(crate) fn print(value: Value, json_output: bool) -> Result<()> {
    if json_output {
        println!("{}", serde_json::to_string(&value)?);
    } else if value.is_null() {
        return Ok(());
    } else if let Some(commit) = value["commit"].as_str() {
        println!(
            "[{} {}] {}",
            value["branch"].as_str().unwrap_or(""),
            &commit[..8],
            paths::terminal(value["message"].as_str().unwrap_or(""))
        );
    } else if let Some(review) = value["review_id"].as_str() {
        println!("Created review {review} for protected main.");
        println!("Inspect: fsc review show {review}");
        println!("After approval and landing: fsc pull");
    } else if let Some(text) = value.as_str() {
        println!("{}", paths::terminal(text));
    } else {
        println!("{}", serde_json::to_string_pretty(&value)?);
    }
    Ok(())
}
pub(crate) fn initial(server: String, repository: String, branch: String, prefix: String) -> State {
    State {
        version: 1,
        server,
        repository,
        current: branch.clone(),
        prefix,
        branches: BTreeMap::from([(
            branch,
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
pub(crate) fn resolve(state: &State, name: &str) -> Result<Option<String>> {
    if name == "HEAD" {
        return Ok(state.head().map(str::to_owned));
    }
    if let Some(branch) = state.branches.get(name) {
        return Ok(branch.head.clone());
    }
    if let Some(name) = name.strip_prefix("origin/") {
        return state
            .remotes
            .get(name)
            .cloned()
            .context("Unknown remote branch");
    }
    if let Some(id) = state.tags.get(name) {
        return Ok(Some(id.clone()));
    }
    paths::revision(name)?;
    Ok(Some(name.to_owned()))
}
pub(crate) fn local_commit(
    state: &mut State,
    message: &str,
    merge_parent: Option<String>,
    files: Files,
) -> Result<String> {
    ensure!(
        !message.trim().is_empty() && message.len() <= 2000,
        "Commit message must contain 1-2,000 bytes"
    );
    let changes = delta(&state.files(), &files);
    ensure!(
        !changes.is_empty() || merge_parent.is_some(),
        "No staged changes"
    );
    ensure!(
        changes.len() <= 100,
        "A commit may change at most 100 files"
    );
    paths::manifest(&files)?;
    let id = uuid::Uuid::new_v4().to_string();
    state.commits.insert(
        id.clone(),
        Commit {
            parent: state.head().map(str::to_owned),
            merge_parent,
            message: message.to_owned(),
            files: files.into(),
            git: None,
        },
    );
    state
        .branches
        .get_mut(&state.current)
        .context("Missing current branch")?
        .head = Some(id.clone());
    state.index.clear();
    Ok(id)
}
pub fn run(args: Args) -> Result<()> {
    if let Some(dir) = &args.directory {
        std::env::set_current_dir(dir)?;
    }
    if crate::bootstrap::run(&args)? {
        return Ok(());
    }
    let disk = Disk::open(&Disk::find()?, false)?;
    if matches!(&args.command, Command::Recover) {
        journal::recover(&disk)?;
        return print(json!({"recovered":true}), args.json);
    }
    journal::ready(&disk)?;
    let mut state: State = disk.load("state.json")?;
    working::validate(&state)?;
    let _ = server(&args, Some(&state))?;
    if !matches!(
        &args.command,
        Command::Push { .. }
            | Command::Status
            | Command::Diff { .. }
            | Command::Log { .. }
            | Command::Show { .. }
            | Command::Remote
    ) {
        push::ready(&disk)?;
    }
    match &args.command {
        Command::Diff { staged } => return crate::display::diff(&disk, &state, *staged, args.json),
        Command::Log { count, oneline } => {
            return crate::display::log(&args, &state, *count, *oneline);
        }
        _ => (),
    }
    if let Some(value) = crate::local::run(&args, &disk, &mut state)? {
        return print(value, args.json);
    }
    if let Some(value) = crate::branches::run(&args, &disk, &mut state)? {
        return print(value, args.json);
    }
    if let Some(value) = crate::sync::run(&args, &disk, &mut state)? {
        return print(value, args.json);
    }
    if let Command::Show { revision } = &args.command {
        let id = resolve(&state, revision.as_deref().unwrap_or("HEAD"))?
            .context("Repository has no commits")?;
        let value = if let Some(commit) = state.commits.get(&id) {
            json!({"id":id,"parent":commit.parent,"merge_parent":commit.merge_parent,"message":commit.message,"files":commit.files})
        } else {
            remote(&args, Some(&state))?.get(
                &format!("/repositories/{}/changesets/{id}", state.repository),
                &[],
            )?
        };
        return print(value, args.json);
    }
    anyhow::bail!("Command requires a working copy")
}
