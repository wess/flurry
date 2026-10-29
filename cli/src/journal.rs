use crate::{
    disk::{self, Disk},
    model::{Files, State, delta},
    paths,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Operation {
    path: String,
    before: Option<String>,
    after: Option<String>,
    #[serde(default)]
    temporary: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Transaction {
    state: State,
    operations: Vec<Operation>,
}

pub fn ready(disk: &Disk) -> Result<()> {
    ensure!(
        disk.meta.symlink_metadata("transaction.json").is_err(),
        "An interrupted working-copy update needs recovery; run fsc recover"
    );
    Ok(())
}
pub fn apply(disk: &Disk, before: &Files, after: &Files, state: State) -> Result<()> {
    ready(disk)?;
    crate::working::validate(&state)?;
    paths::manifest(after)?;
    let changes = delta(before, after);
    let mut operations = Vec::new();
    for (path, target) in changes {
        // refuse topology changes before writing anything; no recursive removal
        if target.is_some() {
            if let Ok(meta) = disk.dir.symlink_metadata(&path) {
                ensure!(
                    meta.is_file(),
                    "File/directory transition or symlink at {path:?}; use a fresh clone"
                );
            }
            let parts: Vec<_> = path.split('/').collect();
            for end in 1..parts.len() {
                if let Ok(meta) = disk.dir.symlink_metadata(parts[..end].join("/")) {
                    ensure!(
                        meta.is_dir(),
                        "File/directory transition requires a fresh clone"
                    );
                }
            }
        }
        let actual = disk.hash(&path)?;
        ensure!(
            actual.as_ref() == before.get(&path) || actual == target,
            "Local edits or untracked file would be overwritten: {path:?}"
        );
        if let Some(hash) = &target {
            disk.verify(hash)?;
        }
        if actual != target {
            operations.push(Operation {
                path,
                before: actual,
                temporary: target
                    .as_ref()
                    .map(|_| format!(".fsctmp{}", uuid::Uuid::new_v4().simple())),
                after: target,
            });
        }
    }
    operations.sort_by_key(|operation| {
        (
            operation.after.is_some(),
            std::cmp::Reverse(operation.path.matches('/').count()),
            operation.path.clone(),
        )
    });
    let transaction = Transaction { state, operations };
    disk.save("transaction.json", &transaction)?;
    recover(disk)
}
pub fn recover(disk: &Disk) -> Result<()> {
    let mut transaction: Transaction = disk.load("transaction.json")?;
    let mut upgraded = false;
    for operation in &mut transaction.operations {
        if operation.after.is_some() && operation.temporary.is_none() {
            operation.temporary = Some(format!(".fsctmp{}", uuid::Uuid::new_v4().simple()));
            upgraded = true;
        }
        if let Some(temporary) = &operation.temporary {
            let suffix = temporary
                .strip_prefix(".fsctmp")
                .context("Invalid recovery temporary name")?;
            uuid::Uuid::parse_str(suffix).context("Invalid recovery temporary name")?;
            ensure!(!temporary.contains('/'), "Invalid temporary path");
        }
    }
    if upgraded {
        disk.save("transaction.json", &transaction)?;
    }
    crate::working::validate(&transaction.state)?;
    ensure!(
        transaction.operations.len() <= crate::model::FILES_LIMIT * 2,
        "Oversized transaction"
    );
    for operation in &transaction.operations {
        paths::valid(&operation.path)?;
        for hash in [&operation.before, &operation.after].into_iter().flatten() {
            paths::hash(hash)?;
        }
        let current = disk.hash(&operation.path)?;
        if current == operation.after {
            if let Some(temporary) = &operation.temporary {
                let (parent, _) = disk.parent(&operation.path, false)?;
                match parent.remove_file(temporary) {
                    Ok(()) => disk::sync(&parent)?,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                    Err(error) => return Err(error.into()),
                }
            }
            continue;
        }
        ensure!(
            current == operation.before,
            "File changed during interrupted update: {:?}. Move your edited file aside, then retry fsc recover.",
            operation.path
        );
        if let Some(hash) = &operation.after {
            disk.verify(hash)?;
            let (parent, name) = disk.parent(&operation.path, true)?;
            let temporary = operation
                .temporary
                .as_ref()
                .context("Missing recovery temporary name")?;
            match parent.remove_file(temporary) {
                Ok(()) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(error) => return Err(error.into()),
            }
            let mut file = disk::create(&parent, temporary)?;
            let result = (|| {
                std::io::copy(&mut disk.object(hash)?, &mut file)?;
                if let Ok(old) = disk.file(&operation.path) {
                    file.set_permissions(old.metadata()?.permissions())?;
                }
                file.sync_all()?;
                ensure!(
                    disk.hash(&operation.path)? == operation.before,
                    "File changed while preparing update; run fsc recover after preserving your edit"
                );
                parent.rename(temporary, &parent, &name)?;
                disk::sync(&parent)
            })();
            let _ = parent.remove_file(temporary);
            result?;
        } else {
            let (parent, name) = disk.parent(&operation.path, false)?;
            parent
                .remove_file(&name)
                .context("Could not remove tracked file; run fsc recover")?;
            disk::sync(&parent)?;
        }
    }
    disk.save_state(&transaction.state)?;
    disk.remove("transaction.json")?;
    Ok(())
}
