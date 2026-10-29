use crate::{
    disk::{self, Disk},
    model::{Edits, State, delta},
    paths,
    remote::Remote,
};
use anyhow::{Context, Result, ensure};
use base64::{engine::general_purpose::STANDARD, write::EncoderWriter};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Write,
};

#[derive(Serialize, Deserialize)]
struct Pending {
    request_id: String,
    branch: String,
    expected: Option<String>,
    head: String,
    commits: Vec<Upload>,
}
#[derive(Serialize, Deserialize)]
struct Upload {
    id: String,
    parent: Option<String>,
    merge_parent: Option<String>,
    message: String,
    files: Edits,
    git: Option<crate::model::GitData>,
}
struct Limited<W> {
    inner: W,
    count: u64,
}
impl<W: Write> Write for Limited<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if self.count + bytes.len() as u64 > 140 * 1024 * 1024 {
            return Err(std::io::Error::other(
                "Push exceeds 140 MiB; push a smaller set of commits",
            ));
        }
        let size = self.inner.write(bytes)?;
        self.count += size as u64;
        Ok(size)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
pub fn ready(disk: &Disk) -> Result<()> {
    ensure!(
        disk.meta.symlink_metadata("push.json").is_err(),
        "A push needs confirmation; rerun fsc push before changing local history"
    );
    Ok(())
}
fn collect(
    state: &State,
    id: &str,
    seen: &mut BTreeSet<String>,
    output: &mut Vec<Upload>,
    depth: usize,
) -> Result<()> {
    if id.len() == 64 || !seen.insert(id.to_owned()) {
        return Ok(());
    }
    ensure!(
        depth <= 100 && seen.len() <= 100,
        "Push at most 100 local commits at a time"
    );
    let commit = state.commits.get(id).context("Missing local commit")?;
    for parent in [&commit.parent, &commit.merge_parent].into_iter().flatten() {
        collect(state, parent, seen, output, depth + 1)?;
    }
    let before = commit
        .parent
        .as_ref()
        .map(|id| {
            state
                .commits
                .get(id)
                .map(|c| c.files.clone())
                .context("Missing parent snapshot")
        })
        .transpose()?
        .unwrap_or_default();
    let files = delta(&before, &commit.files);
    ensure!(
        files.len() <= 100,
        "Each commit may change at most 100 files"
    );
    output.push(Upload {
        id: id.to_owned(),
        parent: commit.parent.clone(),
        merge_parent: commit.merge_parent.clone(),
        message: commit.message.clone(),
        files,
        git: commit.git.clone(),
    });
    Ok(())
}
fn encode(disk: &Disk, pending: &Pending) -> Result<()> {
    let name = format!("request{}", uuid::Uuid::new_v4().simple());
    let result = (|| {
        let mut out = Limited {
            inner: disk::create(&disk.meta, &name)?,
            count: 0,
        };
        write!(
            out,
            "{{\"request_id\":{},\"branch\":{},\"expected\":{},\"head\":{},\"commits\":[",
            serde_json::to_string(&pending.request_id)?,
            serde_json::to_string(&pending.branch)?,
            serde_json::to_string(&pending.expected)?,
            serde_json::to_string(&pending.head)?
        )?;
        for (index, commit) in pending.commits.iter().enumerate() {
            if index != 0 {
                out.write_all(b",")?;
            }
            write!(
                out,
                "{{\"id\":{},\"parent\":{},\"merge_parent\":{},\"message\":{},\"files\":[",
                serde_json::to_string(&commit.id)?,
                serde_json::to_string(&commit.parent)?,
                serde_json::to_string(&commit.merge_parent)?,
                serde_json::to_string(&commit.message)?
            )?;
            for (index, (path, hash)) in commit.files.iter().enumerate() {
                if index != 0 {
                    out.write_all(b",")?;
                }
                write!(out, "{{\"path\":{}", serde_json::to_string(path)?)?;
                if let Some(hash) = hash {
                    out.write_all(b",\"base64\":\"")?;
                    let mut encoder = EncoderWriter::new(&mut out, &STANDARD);
                    let (actual, _) = disk::hash_reader(disk.object(hash)?, Some(&mut encoder))?;
                    ensure!(
                        actual == *hash,
                        "Cached content failed integrity verification"
                    );
                    encoder.finish()?;
                    drop(encoder);
                    out.write_all(b"\"}")?;
                } else {
                    out.write_all(b",\"content\":null}")?;
                }
            }
            out.write_all(b"],\"git\":")?;
            serde_json::to_writer(&mut out, &commit.git)?;
            out.write_all(b"}")?;
        }
        out.write_all(b"]}")?;
        out.inner.sync_all()?;
        disk.meta.rename(&name, &disk.meta, "payload")?;
        disk::sync(&disk.meta)
    })();
    let _ = disk.meta.remove_file(&name);
    result
}
pub fn push(disk: &Disk, state: &mut State, remote: &Remote, tags: bool) -> Result<Value> {
    crate::working::validate(state)?;
    if disk.meta.symlink_metadata("push.json").is_err() {
        let branch = &state.branches[&state.current];
        ensure!(
            branch.review.is_none(),
            "This branch has a pending review. Land it, then pull before pushing more commits"
        );
        let head = state.head().context("Nothing to push")?.to_owned();
        let mut commits = Vec::new();
        collect(state, &head, &mut BTreeSet::new(), &mut commits, 0)?;
        if branch.upstream.as_deref() == Some(&head) && commits.is_empty() {
            if tags {
                push_tags(state, remote)?;
            }
            return Ok(serde_json::json!({"status":"up to date", "head":head}));
        }
        let pending = Pending {
            request_id: uuid::Uuid::new_v4().to_string(),
            branch: state.current.clone(),
            expected: branch.upstream.clone(),
            head,
            commits,
        };
        encode(disk, &pending)?;
        disk.save("push.json", &pending)?;
    }
    let pending: Pending = disk.load("push.json")?;
    paths::name(&pending.branch)?;
    uuid::Uuid::parse_str(&pending.request_id)?;
    ensure!(
        pending.branch == state.current,
        "Pending push belongs to a different branch"
    );
    let result: Value = remote.upload(
        &format!("/repositories/{}/pushes", state.repository),
        disk::read(&disk.meta, "payload")?,
    )?;
    let mapping: BTreeMap<String, String> = serde_json::from_value(result["commits"].clone())?;
    for (old, new) in &mapping {
        uuid::Uuid::parse_str(old)?;
        paths::hash(new)?;
    }
    let expected_keys: BTreeSet<_> = pending
        .commits
        .iter()
        .map(|commit| commit.id.as_str())
        .collect();
    let actual_keys: BTreeSet<_> = mapping.keys().map(String::as_str).collect();
    ensure!(
        actual_keys == expected_keys,
        "Push response commit mapping is incomplete"
    );
    let head = result["head"]
        .as_str()
        .context("Push response has no head")?;
    paths::hash(head)?;
    ensure!(
        mapping
            .get(&pending.head)
            .map(String::as_str)
            .unwrap_or(&pending.head)
            == head,
        "Push response head mismatch"
    );
    ensure!(
        result["branch"].as_str() == Some(&pending.branch),
        "Push response branch mismatch"
    );
    let mut next = state.clone();
    let replace = |id: &mut Option<String>| {
        if let Some(new) = id.as_ref().and_then(|id| mapping.get(id)) {
            *id = Some(new.clone());
        }
    };
    for (old, new) in &mapping {
        if let Some(commit) = next.commits.remove(old) {
            next.commits.insert(new.clone(), commit);
        }
    }
    for commit in next.commits.values_mut() {
        replace(&mut commit.parent);
        replace(&mut commit.merge_parent);
    }
    for branch in next.branches.values_mut() {
        replace(&mut branch.head);
    }
    for target in next.tags.values_mut() {
        if let Some(new) = mapping.get(target) {
            *target = new.clone();
        }
    }
    let branch = next
        .branches
        .get_mut(&pending.branch)
        .context("Missing local branch")?;
    branch.head = Some(head.to_owned());
    if pending.branch == "main" {
        branch.review = result["review_id"].as_str().map(str::to_owned);
    } else {
        branch.upstream = Some(head.to_owned());
        next.remotes
            .insert(pending.branch.clone(), Some(head.to_owned()));
    }
    crate::working::validate(&next)?;
    disk.save_state(&next)?;
    *state = next;
    disk.remove("push.json")?;
    let _ = disk.remove("payload");
    if tags {
        push_tags(state, remote)?;
    }
    Ok(result)
}
pub fn push_tags(state: &State, remote: &Remote) -> Result<()> {
    for (name, target) in &state.tags {
        paths::hash(target)
            .context("Tag points to an unpushed local commit; push its branch first")?;
        let _: Value = remote.post(
            &format!("/repositories/{}/tags", state.repository),
            &serde_json::json!({"name":name, "target":target, "message":state.annotations.get(name)}),
        )?;
    }
    Ok(())
}

pub fn abort(disk: &Disk, state: &mut State, remote: &Remote) -> Result<Value> {
    let pending: Pending = disk
        .load("push.json")
        .context("No pending push to cancel")?;
    uuid::Uuid::parse_str(&pending.request_id)?;
    let receipt: Value = remote.get(
        &format!(
            "/repositories/{}/pushes/{}",
            state.repository, pending.request_id
        ),
        &[],
    )?;
    if receipt["accepted"].as_bool() == Some(true) {
        return push(disk, state, remote, false);
    }
    ensure!(
        receipt["accepted"].as_bool() == Some(false),
        "Server could not confirm push status"
    );
    disk.remove("push.json")?;
    let _ = disk.remove("payload");
    Ok(
        serde_json::json!({"canceled":true,"note":"Server confirmed no accepted push; local commits are preserved."}),
    )
}
