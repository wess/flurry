use crate::{
    args::Args,
    commands::{print, remote},
    disk::Disk,
    model::{State, delta},
    paths, working,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{collections::BTreeSet, io::Read};
pub(crate) fn diff(disk: &Disk, state: &State, staged: bool, json_output: bool) -> Result<()> {
    let before = if staged {
        state.files()
    } else {
        state.staged()
    };
    let after = if staged {
        state.staged()
    } else {
        working::scan(disk, state)?
    };
    let mut changes = delta(&before, &after);
    if !staged {
        changes.retain(|path, _| before.contains_key(path));
    }
    if json_output {
        return print(json!({"changes":changes}), true);
    }
    for (path, next) in changes {
        println!("diff {:?}", path);
        let old = before.get(&path).map(|id| disk.object(id)).transpose()?;
        let new = if staged {
            next.as_ref().map(|id| disk.object(id)).transpose()?
        } else if next.is_some() {
            Some(disk.file(&path)?)
        } else {
            None
        };
        let load = |file: Option<cap_std::fs::File>| -> Result<Vec<u8>> {
            let mut bytes = Vec::new();
            if let Some(file) = file {
                file.take(40_001).read_to_end(&mut bytes)?;
            }
            Ok(bytes)
        };
        let old = load(old)?;
        let new = load(new)?;
        if old.len() + new.len() > 40_000 || old.contains(&0) || new.contains(&0) {
            println!("Binary or large file; inspect with show/download tools");
            continue;
        }
        let (Ok(old), Ok(new)) = (std::str::from_utf8(&old), std::str::from_utf8(&new)) else {
            println!("Binary file");
            continue;
        };
        if old.lines().count() + new.lines().count() > 2000 {
            println!("Too many lines for inline diff");
            continue;
        }
        for change in similar::TextDiff::from_lines(old, new).iter_all_changes() {
            let sign = match change.tag() {
                similar::ChangeTag::Delete => '-',
                similar::ChangeTag::Insert => '+',
                _ => ' ',
            };
            println!(
                "{sign}{}",
                paths::terminal(change.value().trim_end_matches('\n'))
            );
        }
    }
    Ok(())
}
pub(crate) fn log(args: &Args, state: &State, count: u16, oneline: bool) -> Result<()> {
    let mut next = state.head().map(str::to_owned);
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    while let Some(id) = next {
        ensure!(seen.insert(id.clone()), "History cycle in local metadata");
        if result.len() >= count as usize {
            break;
        }
        if let Some(commit) = state.commits.get(&id) {
            result.push(json!({"id":id,"parent":commit.parent,"merge_parent":commit.merge_parent,"message":commit.message}));
            next = commit.parent.clone();
        } else {
            let value: Value = remote(args, Some(state))?.get(
                &format!("/repositories/{}/history", state.repository),
                &[("revision", &id)],
            )?;
            for commit in value["changesets"]
                .as_array()
                .context("Invalid history response")?
            {
                if result.len() >= count as usize {
                    break;
                }
                result.push(commit.clone());
            }
            break;
        }
    }
    if oneline && !args.json {
        for commit in result {
            println!(
                "{} {}",
                &commit["id"].as_str().unwrap_or("")[..8],
                paths::terminal(
                    commit["message"]
                        .as_str()
                        .unwrap_or("")
                        .lines()
                        .next()
                        .unwrap_or("")
                )
            );
        }
        Ok(())
    } else {
        print(json!({"commits":result}), args.json)
    }
}
