use crate::{
    disk::{self, Disk},
    model::{Files, delta},
    paths,
};
use anyhow::{Context, Result, ensure};
use std::io::Read;
#[derive(Clone, PartialEq)]
struct Edit {
    start: usize,
    end: usize,
    lines: Vec<String>,
}
fn edits(base: &str, next: &str) -> Vec<Edit> {
    let diff = similar::TextDiff::from_lines(base, next);
    diff.ops()
        .iter()
        .filter(|operation| operation.tag() != similar::DiffTag::Equal)
        .map(|operation| {
            let old = operation.old_range();
            let new = operation.new_range();
            Edit {
                start: old.start,
                end: old.end,
                lines: diff.new_slices()[new]
                    .iter()
                    .map(|line| line.to_string())
                    .collect(),
            }
        })
        .collect()
}
pub fn text(base: &str, ours: &str, theirs: &str) -> Result<String> {
    ensure!(
        base.len() + ours.len() + theirs.len() <= 40_000
            && base.lines().count() + ours.lines().count() + theirs.lines().count() <= 2000,
        "File is too large for automatic text merging"
    );
    let mut result = edits(base, ours);
    for right in edits(base, theirs) {
        if result.contains(&right) {
            continue;
        }
        for left in &result {
            let overlap = left.start < right.end && right.start < left.end;
            let insertion =
                (left.start == left.end && left.start >= right.start && left.start < right.end)
                    || (right.start == right.end
                        && right.start >= left.start
                        && right.start < left.end)
                    || (left.start == left.end
                        && right.start == right.end
                        && left.start == right.start);
            ensure!(!overlap && !insertion, "Overlapping text edits");
        }
        result.push(right);
    }
    result.sort_by_key(|edit| (edit.start, edit.end));
    let base = base.split_inclusive('\n').collect::<Vec<_>>();
    let mut output = String::new();
    let mut cursor = 0;
    for edit in result {
        ensure!(
            edit.start >= cursor && edit.end <= base.len(),
            "Invalid merge range"
        );
        for line in &base[cursor..edit.start] {
            output.push_str(line);
        }
        for line in edit.lines {
            output.push_str(&line);
        }
        cursor = edit.end;
    }
    for line in &base[cursor..] {
        output.push_str(line);
    }
    Ok(output)
}
fn contents(disk: &Disk, hash: &str) -> Result<String> {
    let mut bytes = Vec::new();
    disk.object(hash)?.take(40_001).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 40_000 && !bytes.contains(&0),
        "Binary or large file"
    );
    ensure!(
        disk::hash_reader(bytes.as_slice(), None)?.0 == hash,
        "Cached content failed integrity verification"
    );
    String::from_utf8(bytes).context("Binary file")
}
pub fn files(disk: &Disk, base: &Files, ours: &Files, theirs: &Files) -> Result<Files> {
    let mut result = ours.clone();
    let mut conflicts = Vec::new();
    for (path, target) in delta(base, theirs) {
        if ours.get(&path) == base.get(&path) || ours.get(&path) == target.as_ref() {
            if let Some(hash) = target {
                result.insert(path, hash);
            } else {
                result.remove(&path);
            }
            continue;
        }
        if let (Some(base), Some(left), Some(right)) =
            (base.get(&path), ours.get(&path), target.as_ref())
        {
            let merged = (|| {
                text(
                    &contents(disk, base)?,
                    &contents(disk, left)?,
                    &contents(disk, right)?,
                )
            })();
            if let Ok(text) = merged {
                let (hash, _) = disk.store(text.as_bytes(), None)?;
                result.insert(path, hash);
                continue;
            }
        }
        conflicts.push(path);
    }
    ensure!(
        conflicts.is_empty(),
        "Merge conflicts (working files unchanged): {}. Resolve conflicting content on a branch, or use Git's conflict-resolution workflow through the Flurry helper.",
        serde_json::to_string(&conflicts)?
    );
    paths::manifest(&result)?;
    Ok(result)
}
