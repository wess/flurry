use clap::{Parser, Subcommand};
use std::path::PathBuf;
#[derive(Parser)]
#[command(
    name = "fsc",
    version,
    about = "Flurry Source Control",
    long_about = "Flurry Source Control. Stage and commit offline, publish topic branches, and send main through review. Remote servers require HTTPS."
)]
pub struct Args {
    #[arg(long, global = true, env = "FLURRY_URL", hide_env_values = true)]
    /// Server origin; defaults to http://127.0.0.1:4040.
    pub server: Option<String>,
    #[arg(long, global = true)]
    /// Emit structured JSON.
    pub json: bool,
    #[arg(short = 'C', global = true)]
    /// Run from this directory.
    pub directory: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Command,
}
#[derive(Subcommand)]
pub enum Command {
    /// Manage authentication and saved credentials.
    Auth {
        #[command(subcommand)]
        command: Auth,
    },
    /// List, create, or import remote repositories.
    Repo {
        #[command(subcommand)]
        command: Repo,
    },
    /// Clone a repository into an empty directory.
    Clone {
        repository: String,
        directory: PathBuf,
        #[arg(short, long, default_value = "main")]
        branch: String,
        #[arg(long)]
        sparse: Option<String>,
    },
    /// Create a private remote repository and initialize this directory.
    Init {
        name: String,
        #[arg(long)]
        public: bool,
    },
    /// Show staged, unstaged, and untracked files.
    Status,
    /// Stage file snapshots, including tracked deletions.
    Add {
        #[arg(short = 'A', long)]
        all: bool,
        #[arg(default_value = ".")]
        paths: Vec<String>,
    },
    /// Record staged snapshots locally without network access.
    Commit {
        #[arg(long)]
        amend: bool,
        #[arg(short, long)]
        message: String,
    },
    /// Compare working files or staged snapshots.
    Diff {
        #[arg(long)]
        staged: bool,
    },
    /// Show first-parent history.
    Log {
        #[arg(short='n', long, default_value_t=20, value_parser=clap::value_parser!(u16).range(1..=100))]
        count: u16,
        #[arg(long)]
        oneline: bool,
    },
    /// Inspect a commit snapshot.
    Show { revision: Option<String> },
    /// List, create, or delete local branches.
    Branch {
        name: Option<String>,
        start: Option<String>,
        #[arg(short = 'd', long)]
        delete: bool,
    },
    #[command(alias = "checkout")]
    /// Switch branches with overwrite protection.
    Switch {
        name: String,
        #[arg(short = 'c', long)]
        create: bool,
    },
    /// List or create lightweight and annotated tags.
    Tag {
        name: Option<String>,
        #[arg(short = 'a', long, requires = "message")]
        annotated: bool,
        #[arg(short, long)]
        message: Option<String>,
        target: Option<String>,
        #[arg(short = 'd', long)]
        delete: bool,
    },
    /// Refresh remote branch and tag information.
    Fetch,
    /// Fetch and fast-forward; refuses divergent local history.
    Pull {
        #[arg(long)]
        ff_only: bool,
    },
    /// Publish commits. main creates a review; topic branches advance atomically.
    Push {
        #[arg(long, conflicts_with = "tags")]
        abort: bool,
        #[arg(long)]
        tags: bool,
    },
    /// Three-way merge. Conflicting files leave the working copy unchanged.
    Merge {
        revision: String,
        #[arg(short, long)]
        message: Option<String>,
    },
    /// Restore selected paths from the index, or unstage with --staged.
    Restore {
        #[arg(long)]
        staged: bool,
        #[arg(required = true)]
        paths: Vec<String>,
    },
    /// Inspect, discuss, approve, or land changes.
    Review {
        #[command(subcommand)]
        command: Review,
    },
    /// Pull from or export to a linked Git provider.
    Source {
        #[command(subcommand)]
        command: Source,
    },
    /// Serve Flurry tools over MCP stdio.
    Mcp {
        /// Expose additive review-comment and evaluation tools.
        #[arg(long)]
        allow_writes: bool,
    },
    /// Show this checkout's server and repository.
    Remote,
    /// Finish an interrupted working-copy transaction without network access.
    Recover,
    /// Remove cached blobs no longer referenced by local snapshots.
    Gc,
}
#[derive(Subcommand)]
pub enum Auth {
    Login {
        #[arg(long, conflicts_with = "email")]
        token_stdin: bool,
        #[arg(long)]
        email: Option<String>,
    },
    Status,
    /// Remove this server's saved credential. Revoke tokens in web settings separately.
    Logout,
}
#[derive(Subcommand)]
pub enum Repo {
    List,
    Create {
        name: String,
        #[arg(long)]
        public: bool,
    },
    Import {
        url: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        branch: Option<String>,
        #[arg(long)]
        token_stdin: bool,
        #[arg(long)]
        username: Option<String>,
    },
}
#[derive(Subcommand)]
pub enum Review {
    List,
    Show {
        id: String,
    },
    Approve {
        id: String,
    },
    Land {
        id: String,
    },
    Comment {
        id: String,
        #[arg(short, long)]
        message: String,
    },
}
#[derive(Subcommand)]
pub enum Source {
    Status,
    Pull {
        #[arg(long)]
        token_stdin: bool,
        #[arg(long)]
        username: Option<String>,
    },
    /// Export exactly this landed main revision to the linked Git branch.
    Push {
        #[arg(long)]
        revision: String,
        #[arg(long)]
        token_stdin: bool,
        #[arg(long)]
        username: Option<String>,
    },
}
