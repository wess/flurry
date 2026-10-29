use crate::{
    args::{Args, Auth, Command, Repo},
    commands::{initial, print, remote, server},
    disk::Disk,
    journal,
    model::Files,
    paths, snapshot,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
pub(crate) fn run(args: &Args) -> Result<bool> {
    match &args.command {
        Command::Auth { command } => {
            let server = server(args, None)?;
            match command {
                Auth::Login { token_stdin, email } => {
                    crate::auth::login(&server, *token_stdin, email.as_deref())?;
                    print(
                        json!({"server":server,"authenticated":true,"storage":"OS credential store"}),
                        args.json,
                    )
                }
                Auth::Logout => {
                    crate::auth::logout(&server)?;
                    print(
                        json!({"removed":true,"note":"Remove FLURRY_TOKEN from your environment too, if set. Server-side tokens remain valid until revoked in settings."}),
                        args.json,
                    )
                }
                Auth::Status => {
                    let _: Value = remote(args, None)?.get("/repositories", &[])?;
                    print(json!({"server":server,"authenticated":true}), args.json)
                }
            }?;
            return Ok(true);
        }
        Command::Repo { command } => {
            let remote = remote(args, None)?;
            let value: Value = match command {
                Repo::List => remote.get("/repositories", &[])?,
                Repo::Create { name, public } => remote.post(
                    "/repositories",
                    &json!({"name":name,"visibility":if *public {"public"} else {"private"}}),
                )?,
                Repo::Import {
                    url,
                    name,
                    branch,
                    token_stdin,
                    username,
                } => {
                    let token = if *token_stdin {
                        Some(crate::auth::stdin_secret()?)
                    } else {
                        None
                    };
                    remote.post("/imports", &json!({"url":url,"name":name,"branch":branch,"token":token.as_ref().map(|s|s.as_str()),"username":username}))?
                }
            };
            print(value, args.json)?;
            return Ok(true);
        }
        Command::Mcp { allow_writes } => {
            crate::mcp::serve(remote(args, None)?, *allow_writes)?;
            return Ok(true);
        }
        Command::Clone {
            repository,
            directory,
            branch,
            sparse,
        } => {
            uuid::Uuid::parse_str(repository)?;
            paths::name(branch)?;
            let prefix = sparse.clone().unwrap_or_default();
            if !prefix.is_empty() {
                paths::valid(&prefix)?;
            }
            if !directory.exists() {
                std::fs::create_dir(directory).context("Destination parent must already exist")?;
            }
            ensure!(
                std::fs::read_dir(directory)?.next().is_none(),
                "Clone destination must be empty"
            );
            let disk = Disk::open(directory, true)?;
            let remote = remote(args, None)?;
            let mut state = initial(
                remote.origin.clone(),
                repository.clone(),
                branch.clone(),
                prefix,
            );
            disk.save_state(&state)?;
            snapshot::fetch(&disk, &mut state, &remote)?;
            let target = state
                .remotes
                .get(branch)
                .context("Remote branch not found")?
                .clone();
            snapshot::capture(&disk, &mut state, &remote, target.as_deref())?;
            state
                .branches
                .get_mut(branch)
                .context("Missing branch")?
                .head = target.clone();
            state
                .branches
                .get_mut(branch)
                .context("Missing branch")?
                .upstream = target;
            journal::apply(&disk, &Files::new(), &state.files(), state.clone())?;
            print(
                json!({"directory":disk.root,"branch":branch,"head":state.head(),"files":state.files().len()}),
                args.json,
            )?;
            return Ok(true);
        }
        Command::Init { name, public } => {
            let disk = Disk::open(std::path::Path::new("."), true)?;
            for entry in disk.meta.entries()? {
                let entry = entry?;
                ensure!(
                    matches!(entry.file_name().to_str(), Some("lock" | "objects")),
                    "Already initialized or recovery data exists; keep .flurry intact"
                );
            }
            ensure!(
                disk.objects.entries()?.next().is_none(),
                "Existing object cache must be preserved; use clone for a separate working copy"
            );
            let remote = remote(args, None)?;
            let repository: Value = remote.post(
                "/repositories",
                &json!({"name":name,"visibility":if *public {"public"} else {"private"}}),
            )?;
            let id = repository["id"].as_str().context("Missing repository ID")?;
            uuid::Uuid::parse_str(id)?;
            disk.save_state(&initial(
                remote.origin,
                id.to_owned(),
                "main".to_owned(),
                String::new(),
            ))?;
            print(
                json!({"repository":id,"next":"fsc add . && fsc commit -m 'Initial commit' && fsc push"}),
                args.json,
            )?;
            return Ok(true);
        }
        _ => (),
    }

    Ok(false)
}
