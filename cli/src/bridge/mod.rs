mod export;
mod git;
mod receive;
use crate::{disk::Disk, remote::Remote};
use anyhow::{Context, Result, bail, ensure};
use git::git;
use std::{
    io::{Read, Write},
    process::Stdio,
};
fn parse(url: &str) -> Result<(String, String)> {
    let url = url.strip_prefix("flurry::").unwrap_or(url);
    let mut url = url::Url::parse(url)?;
    let repository = url.path().trim_matches('/').to_string();
    uuid::Uuid::parse_str(&repository).context("Use flurry::https://host/<repository-uuid>")?;
    url.set_path("/");
    let server = crate::remote::origin(url.as_str())?;
    Ok((server, repository))
}
fn client(server: &str) -> Result<Remote> {
    if std::env::var_os("FLURRY_TOKEN").is_some() {
        let explicit = std::env::var("FLURRY_URL")
            .context("Git helper requires FLURRY_URL alongside FLURRY_TOKEN")?;
        ensure!(
            crate::remote::origin(&explicit)? == server,
            "Git remote and FLURRY_URL disagree; refusing to forward credential"
        );
    }
    Remote::new(server, crate::auth::token(server, true)?)
}
fn line(input: &mut impl Read) -> Result<Option<String>> {
    let mut bytes = Vec::new();
    let mut byte = [0];
    loop {
        if input.read(&mut byte)? == 0 {
            if bytes.is_empty() {
                return Ok(None);
            }
            bail!("Truncated remote-helper command");
        }
        if byte[0] == b'\n' {
            break;
        }
        bytes.push(byte[0]);
        ensure!(bytes.len() <= 4096, "Oversized remote-helper command");
    }
    Ok(Some(String::from_utf8(bytes)?))
}
pub fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if matches!(args.get(1).map(String::as_str), Some("--version" | "-V")) {
        println!("git-remote-flurry {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if matches!(args.get(1).map(String::as_str), Some("--help" | "-h")) {
        println!(
            "Git transport for Flurry. Install alongside fsc, then use: git clone flurry::https://host/REPOSITORY_UUID"
        );
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("--receive") {
        return receive::run();
    }
    let (server, repository) = parse(
        args.get(2)
            .context("git-remote-flurry is invoked by Git, not directly")?,
    )?;
    let mut input = std::io::stdin();
    while let Some(command) = line(&mut input)? {
        if command == "capabilities" {
            println!("connect\n");
            std::io::stdout().flush()?;
        } else if command.starts_with("connect ") {
            let service = command.trim_start_matches("connect ");
            ensure!(
                ["git-upload-pack", "git-receive-pack"].contains(&service),
                "Unsupported Git service"
            );
            let temporary = tempfile::tempdir()?;
            let disk = Disk::open(temporary.path(), true)?;
            let remote = client(&server)?;
            export::mirror(&disk, &remote, &repository)?;
            let root = disk.root.clone();
            drop(disk);
            if service == "git-receive-pack" {
                receive::hook(&root)?;
            }
            println!();
            std::io::stdout().flush()?;
            let executable = std::env::current_exe()?;
            let status = git(&root)
                .arg("-c")
                .arg(format!("core.hooksPath={}", root.join("hooks").display()))
                .arg(service.trim_start_matches("git-"))
                .arg(".")
                .env("FSC_HELPER", executable)
                .env("FSC_BRIDGE_ROOT", &root)
                .env("FSC_SERVER", &server)
                .stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit())
                .status()?;
            ensure!(status.success(), "Git service failed");
            return Ok(());
        } else if command.is_empty() {
            return Ok(());
        } else {
            bail!("Unsupported remote-helper command");
        }
    }
    Ok(())
}
