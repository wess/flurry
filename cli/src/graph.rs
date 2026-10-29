use crate::{model::State, remote::Remote};
use anyhow::{Context, Result, ensure};
use std::collections::{BTreeMap, VecDeque};

fn frontier(state: &State, head: Option<&str>) -> Result<BTreeMap<Option<String>, usize>> {
    let mut seen = BTreeMap::new();
    let mut queue = VecDeque::from([(head.map(str::to_owned), 0)]);
    while let Some((id, depth)) = queue.pop_front() {
        if seen.contains_key(&id) {
            continue;
        }
        ensure!(
            seen.len() <= 2000,
            "Local history traversal exceeds 2,000 nodes"
        );
        seen.insert(id.clone(), depth);
        if let Some(id) = id
            && id.len() != 64
        {
            let commit = state.commits.get(&id).context("Missing local commit")?;
            queue.push_back((commit.parent.clone(), depth + 1));
            if commit.merge_parent.is_some() {
                queue.push_back((commit.merge_parent.clone(), depth + 1));
            }
        }
    }
    Ok(seen)
}
struct Ancestry<'a> {
    state: &'a State,
    remote: &'a Remote,
    cache: BTreeMap<(String, String), bool>,
    calls: usize,
}
impl Ancestry<'_> {
    fn remote(&mut self, a: &str, b: &str) -> Result<bool> {
        if a == b {
            return Ok(true);
        }
        if let Some(result) = self.cache.get(&(a.to_owned(), b.to_owned())) {
            return Ok(*result);
        }
        self.calls += 1;
        ensure!(
            self.calls <= 256,
            "Complex ancestry exceeds the comparison budget; resolve using Git"
        );
        let response: serde_json::Value = self.remote.get(
            &format!("/repositories/{}/ancestry", self.state.repository),
            &[("ancestor", a), ("descendant", b)],
        )?;
        let result = response["ancestor"]
            .as_bool()
            .context("Invalid ancestry response")?;
        self.cache.insert((a.to_owned(), b.to_owned()), result);
        Ok(result)
    }
    fn contains(&mut self, a: &str, b: &str) -> Result<bool> {
        if a == b {
            return Ok(true);
        }
        if b.len() == 64 {
            return if a.len() == 64 {
                self.remote(a, b)
            } else {
                Ok(false)
            };
        }
        let seen = frontier(self.state, Some(b))?;
        if seen.contains_key(&Some(a.to_owned())) {
            return Ok(true);
        }
        if a.len() != 64 {
            return Ok(false);
        }
        for leaf in seen.into_keys().flatten().filter(|id| id.len() == 64) {
            if self.remote(a, &leaf)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
}
pub fn base(
    state: &State,
    remote: &Remote,
    left: Option<&str>,
    right: Option<&str>,
) -> Result<Option<String>> {
    if left == right {
        return Ok(left.map(str::to_owned));
    }
    if left.is_none() || right.is_none() {
        return Ok(None);
    }
    let a = frontier(state, left)?;
    let b = frontier(state, right)?;
    let common: std::collections::BTreeSet<_> = a
        .keys()
        .filter(|id| b.contains_key(*id))
        .flatten()
        .cloned()
        .collect();
    let mut parents = std::collections::BTreeSet::new();
    for id in &common {
        if id.len() != 64 {
            let commit = state.commits.get(id).context("Missing merge ancestor")?;
            parents.extend(
                [commit.parent.clone(), commit.merge_parent.clone()]
                    .into_iter()
                    .flatten(),
            );
        }
    }
    let mut candidates: std::collections::BTreeSet<_> = common
        .into_iter()
        .filter(|id| !parents.contains(id))
        .collect();
    let leaves = |set: BTreeMap<Option<String>, usize>| {
        set.into_keys()
            .flatten()
            .filter(|id| id.len() == 64)
            .collect::<Vec<_>>()
    };
    let a = leaves(a);
    let b = leaves(b);
    ensure!(
        a.len() * b.len() <= 64,
        "Complex merge ancestry requires manual resolution"
    );
    for left in &a {
        for right in &b {
            if left == right {
                candidates.insert(left.clone());
                continue;
            }
            let result: serde_json::Value = remote.get(
                &format!("/repositories/{}/mergebase", state.repository),
                &[("left", left), ("right", right)],
            )?;
            if let Some(id) = result["base"].as_str() {
                crate::paths::hash(id)?;
                candidates.insert(id.to_owned());
            }
        }
    }
    ensure!(
        candidates.len() <= 16,
        "Complex merge ancestry requires manual resolution"
    );
    let candidates = candidates.into_iter().collect::<Vec<_>>();
    let mut ancestry = Ancestry {
        state,
        remote,
        cache: BTreeMap::new(),
        calls: 0,
    };
    let mut lowest = Vec::new();
    for candidate in &candidates {
        let mut dominated = false;
        for other in &candidates {
            if other != candidate && ancestry.contains(candidate, other)? {
                dominated = true;
                break;
            }
        }
        if !dominated {
            lowest.push(candidate.clone());
        }
    }
    ensure!(
        lowest.len() <= 1,
        "Multiple merge bases require manual resolution; no files changed"
    );
    Ok(lowest.into_iter().next())
}
