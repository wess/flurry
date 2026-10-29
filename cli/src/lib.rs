#![forbid(unsafe_code)]
pub mod args;
pub mod auth;
pub mod bridge;
pub mod commands;
pub mod disk;
pub mod graph;
pub mod journal;
pub mod mcp;
pub mod model;
pub mod paths;
pub mod push;
pub mod remote;
pub mod snapshot;
pub mod working;

mod bootstrap;
mod branches;
mod display;
mod local;
mod sync;

pub mod merge;
