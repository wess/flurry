use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const FILE_LIMIT: u64 = 100 * 1024 * 1024;
pub const BYTE_LIMIT: u64 = 1024 * 1024 * 1024;
pub const FILES_LIMIT: usize = 100_000;
pub const META_LIMIT: u64 = 32 * 1024 * 1024;
pub type Files = BTreeMap<String, String>;
pub type Edits = BTreeMap<String, Option<String>>;

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Commit {
    pub parent: Option<String>,
    pub merge_parent: Option<String>,
    pub message: String,
    pub files: std::sync::Arc<Files>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git: Option<GitData>,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Branch {
    pub head: Option<String>,
    pub upstream: Option<String>,
    pub review: Option<String>,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub version: u32,
    pub server: String,
    pub repository: String,
    pub current: String,
    pub prefix: String,
    pub branches: BTreeMap<String, Branch>,
    pub remotes: BTreeMap<String, Option<String>>,
    pub tags: Files,
    #[serde(default)]
    pub annotations: BTreeMap<String, String>,
    pub commits: BTreeMap<String, Commit>,
    pub index: Edits,
}
impl State {
    pub fn head(&self) -> Option<&str> {
        self.branches[&self.current].head.as_deref()
    }
    pub fn files(&self) -> Files {
        self.head()
            .map(|id| self.commits[id].files.as_ref().clone())
            .unwrap_or_default()
    }
    pub fn staged(&self) -> Files {
        apply(&self.files(), &self.index)
    }
}
pub fn apply(files: &Files, edits: &Edits) -> Files {
    let mut files = files.clone();
    for (path, hash) in edits {
        if let Some(hash) = hash {
            files.insert(path.clone(), hash.clone());
        } else {
            files.remove(path);
        }
    }
    files
}
pub fn delta(a: &Files, b: &Files) -> Edits {
    a.keys()
        .chain(b.keys())
        .filter(|p| a.get(*p) != b.get(*p))
        .map(|p| (p.clone(), b.get(p).cloned()))
        .collect()
}
pub fn merge(base: &Files, ours: &Files, theirs: &Files) -> anyhow::Result<Files> {
    let mut result = ours.clone();
    let mut conflicts = Vec::new();
    for (path, target) in delta(base, theirs) {
        if ours.get(&path) == base.get(&path) || ours.get(&path) == target.as_ref() {
            if let Some(hash) = target {
                result.insert(path, hash);
            } else {
                result.remove(&path);
            }
        } else {
            conflicts.push(path);
        }
    }
    anyhow::ensure!(
        conflicts.is_empty(),
        "Merge conflicts (no files changed): {}",
        serde_json::to_string(&conflicts)?
    );
    crate::paths::manifest(&result)?;
    Ok(result)
}

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct GitData {
    pub id: String,
    pub raw: String,
    pub modes: Files,
}
