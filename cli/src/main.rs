use clap::Parser;
fn main() -> std::process::ExitCode {
    match fsc::commands::run(fsc::args::Args::parse()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("fsc: {}", fsc::paths::terminal(&format!("{error:#}")));
            std::process::ExitCode::FAILURE
        }
    }
}
