fn main() -> std::process::ExitCode {
    match fsc::bridge::run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("flurry: {}", fsc::paths::terminal(&format!("{error:#}")));
            std::process::ExitCode::FAILURE
        }
    }
}
