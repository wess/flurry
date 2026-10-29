use crate::{
    model::{FILE_LIMIT, META_LIMIT},
    paths,
};
use anyhow::{Context, Result, ensure};
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::fs::{Dir, File, OpenOptions};
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    cell::Cell,
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub struct Disk {
    pub root: PathBuf,
    pub dir: Dir,
    pub meta: Dir,
    pub objects: Dir,
    cache_bytes: Cell<u64>,
    _lock: std::fs::File,
}
pub fn read(dir: &Dir, path: &str) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).follow(FollowSymlinks::No);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
    }
    let file = dir.open_with(path, &options)?;
    ensure!(
        file.metadata()?.is_file(),
        "Expected a regular file: {path:?}"
    );
    Ok(file)
}
pub fn create(dir: &Dir, path: &str) -> Result<File> {
    let mut options = OpenOptions::new();
    options
        .write(true)
        .create_new(true)
        .follow(FollowSymlinks::No);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(dir.open_with(path, &options)?)
}
pub fn sync(dir: &Dir) -> Result<()> {
    #[cfg(unix)]
    dir.try_clone()?.into_std_file().sync_all()?;
    Ok(())
}
pub fn directory(dir: &Dir, name: &str) -> Result<Dir> {
    match dir.open_dir_nofollow(name) {
        Ok(dir) => Ok(dir),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut builder = cap_std::fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use cap_std::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            dir.create_dir_with(name, &builder)?;
            sync(dir)?;
            Ok(dir.open_dir_nofollow(name)?)
        }
        Err(error) => Err(error).context("Symlinks are not allowed in working-copy paths"),
    }
}
impl Disk {
    pub fn find() -> Result<PathBuf> {
        let cwd = std::env::current_dir()?;
        for path in cwd.ancestors() {
            if path.join(".flurry").symlink_metadata().is_ok() {
                return Ok(path.to_path_buf());
            }
        }
        anyhow::bail!("Not a Flurry working copy; use fsc init or fsc clone")
    }
    pub fn open(root: &Path, initialize: bool) -> Result<Self> {
        ensure!(
            !root.symlink_metadata()?.file_type().is_symlink(),
            "Working-copy root cannot be a symlink"
        );
        let root = root.canonicalize()?;
        let dir = Dir::open_ambient_dir(&root, cap_std::ambient_authority())?;
        if !initialize {
            ensure!(
                dir.symlink_metadata(".flurry")?.is_dir(),
                "Invalid .flurry directory"
            );
        }
        let meta = directory(&dir, ".flurry")?;
        let objects = directory(&meta, "objects")?;
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(true)
            .follow(FollowSymlinks::No);
        #[cfg(unix)]
        {
            use cap_std::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
        }
        let lock = meta.open_with("lock", &options)?;
        ensure!(
            lock.metadata()?.is_file(),
            "Working-copy lock must be a regular file"
        );
        let lock = lock.into_std();
        lock.try_lock()
            .context("Another fsc command holds this working copy; no files changed")?;
        let mut cache_bytes = 0u64;
        let mut entries = 0usize;
        for entry in objects.entries()? {
            let entry = entry?;
            entries += 1;
            ensure!(
                entries <= crate::model::FILES_LIMIT * 2 && entry.file_type()?.is_file(),
                "Invalid or oversized object cache"
            );
            cache_bytes += entry.metadata()?.len();
        }
        ensure!(
            cache_bytes <= crate::model::BYTE_LIMIT,
            "Object cache exceeds 1 GiB; preserve .flurry and remove orphaned cache files"
        );
        Ok(Self {
            root,
            dir,
            meta,
            objects,
            cache_bytes: Cell::new(cache_bytes),
            _lock: lock,
        })
    }
    pub fn load<T: DeserializeOwned>(&self, name: &str) -> Result<T> {
        let mut bytes = Vec::new();
        read(&self.meta, name)?
            .take(META_LIMIT + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= META_LIMIT,
            "Working-copy metadata exceeds 32 MiB"
        );
        serde_json::from_slice(&bytes).context(
            "Invalid working-copy metadata; legacy Bun checkouts require a fresh fsc clone",
        )
    }
    pub fn save_state(&self, state: &crate::model::State) -> Result<()> {
        crate::working::validate(state)?;
        self.save("state.json", state)
    }
    pub fn save<T: Serialize>(&self, name: &str, value: &T) -> Result<()> {
        let bytes = serde_json::to_vec(value)?;
        ensure!(
            bytes.len() as u64 <= META_LIMIT,
            "Working-copy metadata exceeds 32 MiB"
        );
        self.atomic(&self.meta, name, &bytes)
    }
    pub fn atomic(&self, dir: &Dir, name: &str, bytes: &[u8]) -> Result<()> {
        let temporary = format!("tmp{}", uuid::Uuid::new_v4().simple());
        let mut file = create(dir, &temporary)?;
        let result = (|| {
            file.write_all(bytes)?;
            file.sync_all()?;
            dir.rename(&temporary, dir, name)?;
            sync(dir)
        })();
        let _ = dir.remove_file(&temporary);
        result
    }
    pub fn parent(&self, path: &str, mkdir: bool) -> Result<(Dir, String)> {
        paths::valid(path)?;
        let mut parts = path.split('/').collect::<Vec<_>>();
        let name = parts.pop().context("Missing filename")?.to_string();
        let mut dir = self.dir.try_clone()?;
        for part in parts {
            dir = if mkdir {
                directory(&dir, part)?
            } else {
                dir.open_dir_nofollow(part)
                    .context("Symlink or missing parent directory")?
            };
        }
        Ok((dir, name))
    }
    pub fn file(&self, path: &str) -> Result<File> {
        let (dir, name) = self.parent(path, false)?;
        read(&dir, &name)
    }
    pub fn hash(&self, path: &str) -> Result<Option<String>> {
        paths::valid(path)?;
        // missing paths are deletions; a symlink or a non-file is always an error
        match self.dir.symlink_metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            Ok(metadata) => ensure!(metadata.is_file(), "Symlink or non-regular file: {path:?}"),
        }
        Ok(Some(hash_reader(self.file(path)?, None)?.0))
    }
    pub fn object(&self, hash: &str) -> Result<File> {
        paths::hash(hash)?;
        read(&self.objects, hash)
    }
    pub fn store(&self, input: impl Read, expected: Option<&str>) -> Result<(String, u64)> {
        let name = format!("tmp{}", uuid::Uuid::new_v4().simple());
        let mut out = create(&self.objects, &name)?;
        let result = (|| {
            let (hash, size) = hash_reader(input, Some(&mut out))?;
            if let Some(expected) = expected {
                ensure!(hash == expected, "Content integrity check failed");
            }
            let old_size = self
                .objects
                .symlink_metadata(&hash)
                .ok()
                .map(|m| m.len())
                .unwrap_or(0);
            let used = self.cache_bytes.get().saturating_sub(old_size) + size;
            ensure!(
                used <= crate::model::BYTE_LIMIT,
                "Object cache exceeds 1 GiB; run fsc gc or use a fresh clone"
            );
            out.sync_all()?;
            self.objects.rename(&name, &self.objects, &hash)?;
            sync(&self.objects)?;
            self.cache_bytes.set(used);
            Ok((hash, size))
        })();
        let _ = self.objects.remove_file(&name);
        result
    }
    pub fn verify(&self, hash: &str) -> Result<()> {
        ensure!(
            hash_reader(self.object(hash)?, None)?.0 == hash,
            "Cached object failed integrity verification"
        );
        Ok(())
    }
    pub fn remove(&self, name: &str) -> Result<()> {
        self.meta.remove_file(name)?;
        sync(&self.meta)
    }
}
pub fn hash_reader(
    mut input: impl Read,
    mut output: Option<&mut dyn Write>,
) -> Result<(String, u64)> {
    let mut hasher = Sha256::new();
    hasher.update(b"blob\0");
    let mut bytes = [0u8; 64 * 1024];
    let mut total = 0;
    loop {
        let count = input.read(&mut bytes)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        ensure!(total <= FILE_LIMIT, "File exceeds 100 MiB");
        hasher.update(&bytes[..count]);
        if let Some(out) = &mut output {
            out.write_all(&bytes[..count])?;
        }
    }
    Ok((hex::encode(hasher.finalize()), total))
}
