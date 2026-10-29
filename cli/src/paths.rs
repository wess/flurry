use anyhow::{Result, bail, ensure};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;

pub fn valid(path: &str) -> Result<()> {
    ensure!(
        !path.is_empty() && path.len() <= 1024 && !path.contains('\\'),
        "Invalid repository path: {path:?}"
    );
    ensure!(path.split('/').count() <= 64, "Path depth exceeds 64");
    for part in path.split('/') {
        let lower = part.to_lowercase();
        let stem = lower.split('.').next().unwrap_or("");
        ensure!(
            !part.is_empty() && part != "." && part != ".." && part.len() <= 255,
            "Invalid path component: {part:?}"
        );
        ensure!(
            !part.ends_with(['.', ' '])
                && !part.chars().any(|c| c.is_control()
                    || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
                    || "<>:\"|?*".contains(c)),
            "Nonportable path component: {part:?}"
        );
        ensure!(
            ![".flurry", ".git"].contains(&lower.as_str())
                && !["con", "prn", "aux", "nul"].contains(&stem)
                && !((stem.starts_with("com") || stem.starts_with("lpt"))
                    && stem.len() == 4
                    && stem.as_bytes()[3].is_ascii_digit()),
            "Reserved path component: {part:?}"
        );
    }
    Ok(())
}
pub fn hash(id: &str) -> Result<()> {
    ensure!(
        id.len() == 64
            && id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "Invalid content identifier"
    );
    Ok(())
}
pub fn revision(id: &str) -> Result<()> {
    if id.len() == 64 {
        hash(id)
    } else {
        uuid::Uuid::parse_str(id)?;
        Ok(())
    }
}
pub fn name(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 200
            && value.as_bytes()[0].is_ascii_alphanumeric()
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-/".contains(&b))
            && !value.contains("..")
            && !value.split('/').any(|p| p.is_empty()
                || p.starts_with('.')
                || p.ends_with('.')
                || p.ends_with(".lock")),
        "Invalid branch or tag name: {value:?}"
    );
    Ok(())
}
pub fn manifest(files: &crate::model::Files) -> Result<()> {
    ensure!(
        files.len() <= crate::model::FILES_LIMIT,
        "Checkout exceeds 100,000 files"
    );
    let mut seen = BTreeSet::new();
    for path in files.keys() {
        valid(path)?;
        let parts: Vec<_> = path.split('/').collect();
        for index in 1..parts.len() {
            let parent = parts[..index].join("/");
            ensure!(
                !files.contains_key(&parent),
                "File/directory collision: {parent:?}"
            );
        }
        let folded: String = path.nfc().flat_map(char::to_lowercase).collect();
        ensure!(seen.insert(folded), "Case or Unicode collision: {path:?}");
    }
    // directory names must not alias even when their child filenames differ
    let mut names = std::collections::BTreeMap::new();
    for path in files.keys() {
        let mut prefix = String::new();
        for part in path.split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(part);
            let folded: String = prefix.nfc().flat_map(char::to_lowercase).collect();
            if let Some(old) = names.insert(folded, prefix.clone())
                && old != prefix
            {
                bail!("Case or Unicode directory collision");
            }
        }
    }
    Ok(())
}
pub fn terminal(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}') {
                c.escape_default().to_string().chars().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}
