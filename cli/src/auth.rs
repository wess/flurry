use crate::remote::Remote;
use anyhow::{Context, Result, ensure};
use std::io::{self, Read, Write};
use zeroize::Zeroizing;

fn entry(server: &str) -> Result<keyring::Entry> {
    keyring::Entry::new("flurry.fsc", server)
        .context("OS credential store unavailable; use FLURRY_TOKEN with an explicit FLURRY_URL")
}
pub fn token(server: &str, explicit: bool) -> Result<Option<Zeroizing<String>>> {
    if let Ok(token) = std::env::var("FLURRY_TOKEN") {
        ensure!(
            explicit,
            "FLURRY_TOKEN requires --server or FLURRY_URL, so a checkout cannot redirect your credential"
        );
        return Ok(Some(Zeroizing::new(token)));
    }
    match entry(server)?.get_password() {
        Ok(token) => Ok(Some(Zeroizing::new(token))),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Ok(None),
    }
}
pub fn stdin_secret() -> Result<Zeroizing<String>> {
    let mut text = Zeroizing::new(String::new());
    io::stdin().take(4097).read_to_string(&mut text)?;
    ensure!(text.len() <= 4096, "Credential input is too long");
    Ok(Zeroizing::new(
        text.trim_end_matches(['\r', '\n']).to_string(),
    ))
}
pub fn prompt(label: &str) -> Result<Zeroizing<String>> {
    Ok(Zeroizing::new(rpassword::prompt_password(label)?))
}
pub fn login(server: &str, stdin: bool, email: Option<&str>) -> Result<()> {
    let secret = if stdin {
        stdin_secret()?
    } else {
        prompt(if email.is_some() {
            "Password: "
        } else {
            "Access token: "
        })?
    };
    let token = if let Some(email) = email {
        eprint!("Authenticator or recovery code (Enter if disabled): ");
        io::stderr().flush()?;
        let code = prompt("")?;
        let remote = Remote::new(server, None)?;
        let mut result: serde_json::Value = remote.post("/login", &serde_json::json!({"email": email, "password": secret.as_str(), "code": code.as_str()}))?;
        let token = result["token"]
            .as_str()
            .context("Login returned no credential")?
            .to_owned();
        result["token"] = serde_json::Value::Null;
        Zeroizing::new(token)
    } else {
        secret
    };
    let remote = Remote::new(server, Some(Zeroizing::new(token.to_string())))?;
    let _: serde_json::Value = remote.get("/repositories", &[])?;
    entry(server)?
        .set_password(token.as_str())
        .context("Could not save credential in the OS store; no plaintext fallback was written")?;
    Ok(())
}
pub fn logout(server: &str) -> Result<()> {
    match entry(server)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(error).context("Could not remove OS credential"),
    }
}
