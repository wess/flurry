use crate::paths;
use anyhow::{Context, Result, bail, ensure};
use std::{
    io::Read,
    path::Path,
    process::{Command, Stdio},
};
pub(super) fn git(root: &Path) -> Command {
    let mut command = Command::new("git");
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("GIT_") {
            command.env_remove(key);
        }
    }
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env(
            "GIT_CONFIG_GLOBAL",
            if cfg!(windows) { "NUL" } else { "/dev/null" },
        )
        .env("LC_ALL", "C")
        .arg("-c")
        .arg("core.autocrlf=false")
        .arg("-c")
        .arg("pack.threads=1")
        .arg("-c")
        .arg("pack.windowMemory=32m")
        .arg("-c")
        .arg("pack.deltaCacheSize=16m")
        .arg("-c")
        .arg("core.packedGitLimit=64m")
        .arg("-c")
        .arg("core.packedGitWindowSize=16m")
        .arg("-c")
        .arg("receive.maxInputSize=268435456")
        .arg("-C")
        .arg(root);
    if std::env::var_os("FSC_BRIDGE_ROOT").as_deref() == Some(root.as_os_str())
        && let Some(quarantine) = std::env::var_os("GIT_OBJECT_DIRECTORY")
        && Path::new(&quarantine)
            .canonicalize()
            .is_ok_and(|p| p.starts_with(root.join("objects")))
    {
        command.env("GIT_OBJECT_DIRECTORY", quarantine);
        command.env("GIT_ALTERNATE_OBJECT_DIRECTORIES", root.join("objects"));
    }
    command
}
pub(super) fn output(
    root: &Path,
    args: &[&str],
    input: Option<&mut dyn Read>,
    limit: u64,
) -> Result<Vec<u8>> {
    let errorfile = tempfile::tempfile()?;
    let mut child = git(root)
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::from(errorfile.try_clone()?))
        .spawn()
        .context("Git 2.40+ must be installed for Git compatibility")?;
    if let Some(input) = input {
        std::io::copy(input, &mut child.stdin.take().context("Missing Git input")?)?;
    }
    let mut bytes = Vec::new();
    child
        .stdout
        .take()
        .context("Missing Git output")?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        let _ = child.kill();
        let _ = child.wait();
        bail!("Git output exceeded its safety limit");
    }
    let status = child.wait()?;
    if !status.success() {
        use std::io::{Seek, SeekFrom};
        let mut errors = errorfile;
        errors.seek(SeekFrom::Start(0))?;
        let mut message = String::new();
        errors.take(4096).read_to_string(&mut message)?;
        bail!("Git operation failed: {}", paths::terminal(&message));
    }
    Ok(bytes)
}
pub(super) fn object(root: &Path, kind: &str, input: &mut dyn Read, size: u64) -> Result<String> {
    use sha1::{Digest, Sha1};
    use std::io::Write;
    ensure!(
        size <= crate::model::FILE_LIMIT,
        "Git object exceeds 100 MiB"
    );
    let directory = root.join("objects");
    let mut temporary = tempfile::NamedTempFile::new_in(&directory)?;
    let header = format!("{kind} {size}\0");
    let mut hash = Sha1::new();
    hash.update(header.as_bytes());
    let mut compressed =
        flate2::write::ZlibEncoder::new(temporary.as_file_mut(), flate2::Compression::fast());
    compressed.write_all(header.as_bytes())?;
    let mut bytes = [0; 64 * 1024];
    let mut total = 0;
    loop {
        let count = input.read(&mut bytes)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        ensure!(total <= size, "Git object size mismatch");
        hash.update(&bytes[..count]);
        compressed.write_all(&bytes[..count])?;
    }
    ensure!(total == size, "Truncated Git object");
    compressed.finish()?.sync_all()?;
    let id = hex::encode(hash.finalize());
    let parent = directory.join(&id[..2]);
    std::fs::create_dir_all(&parent)?;
    temporary
        .persist(parent.join(&id[2..]))
        .map_err(|error| error.error)?;
    Ok(id)
}
pub(super) fn git_id(id: &str) -> Result<()> {
    ensure!(
        id.len() == 40
            && id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "Git bridge currently supports SHA-1 repositories"
    );
    Ok(())
}

pub(super) struct Batch {
    child: std::process::Child,
    input: std::process::ChildStdin,
    output: std::io::BufReader<std::process::ChildStdout>,
}
impl Batch {
    pub(super) fn new(root: &Path) -> Result<Self> {
        let mut child = git(root)
            .args(["cat-file", "--batch"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        Ok(Self {
            input: child.stdin.take().context("Missing batch input")?,
            output: std::io::BufReader::new(child.stdout.take().context("Missing batch output")?),
            child,
        })
    }
    pub(super) fn blob(&mut self, id: &str, disk: &crate::disk::Disk) -> Result<String> {
        use std::io::{BufRead, Write};
        git_id(id)?;
        writeln!(self.input, "{id}")?;
        self.input.flush()?;
        let mut header = String::new();
        self.output.by_ref().take(256).read_line(&mut header)?;
        ensure!(header.ends_with('\n'), "Invalid Git batch header");
        let fields = header.split_whitespace().collect::<Vec<_>>();
        ensure!(
            fields.len() == 3 && fields[0] == id && fields[1] == "blob",
            "Expected Git blob"
        );
        let size = fields[2].parse::<u64>()?;
        ensure!(size <= crate::model::FILE_LIMIT, "Git blob exceeds 100 MiB");
        let (hash, count) = disk.store(self.output.by_ref().take(size), None)?;
        ensure!(count == size, "Truncated Git blob");
        let mut newline = [0];
        self.output.read_exact(&mut newline)?;
        ensure!(newline == *b"\n", "Invalid Git batch framing");
        Ok(hash)
    }
}
impl Drop for Batch {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
