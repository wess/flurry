use crate::model::{FILE_LIMIT, META_LIMIT};
use anyhow::{Context, Result, bail, ensure};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::{
    io::{Read, Write},
    time::Duration,
};
use url::Url;
use zeroize::Zeroizing;

pub fn origin(value: &str) -> Result<String> {
    let url = Url::parse(value).context("Server must be an HTTP(S) origin")?;
    ensure!(
        url.scheme() == "https"
            || (url.scheme() == "http"
                && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))),
        "Remote servers require HTTPS; HTTP is allowed only on loopback"
    );
    ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.path() == "/"
            && url.query().is_none()
            && url.fragment().is_none(),
        "Server must be an origin without credentials, path, query, or fragment"
    );
    Ok(url.origin().ascii_serialization())
}
pub struct Remote {
    pub origin: String,
    agent: ureq::Agent,
    token: Option<Zeroizing<String>>,
}
impl Remote {
    pub fn new(server: &str, token: Option<Zeroizing<String>>) -> Result<Self> {
        let origin = origin(server)?;
        if let Some(token) = &token {
            ensure!(
                !token.is_empty()
                    && token.len() <= 4096
                    && token.bytes().all(|b| b.is_ascii_graphic()),
                "Invalid credential"
            );
        }
        let config = ureq::Agent::config_builder()
            .max_redirects(0)
            .proxy(None)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(120)))
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_resolve(Some(Duration::from_secs(10)))
            .timeout_per_read(Some(Duration::from_secs(30)))
            .max_idle_connections(2)
            .max_response_header_size(32 * 1024)
            .user_agent(concat!("fsc/", env!("CARGO_PKG_VERSION")))
            .build();
        Ok(Self {
            origin,
            agent: config.into(),
            token,
        })
    }
    fn url(&self, path: &str, query: &[(&str, &str)]) -> Result<Url> {
        ensure!(
            path.starts_with('/') && !path.starts_with("//") && !path.contains(['?', '#']),
            "Invalid API route"
        );
        let mut url = Url::parse(&(self.origin.clone() + "/api" + path))?;
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query);
        }
        Ok(url)
    }
    fn checked(
        &self,
        mut response: ureq::http::Response<ureq::Body>,
    ) -> Result<ureq::http::Response<ureq::Body>> {
        if !response.status().is_success() {
            let status = response.status().as_u16();
            let mut bytes = Vec::new();
            response
                .body_mut()
                .as_reader()
                .take(65_536)
                .read_to_end(&mut bytes)?;
            let data: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let message = data["error"].as_str().unwrap_or("Request rejected");
            let message = if let Some(token) = &self.token {
                message.replace(token.as_str(), "[redacted]")
            } else {
                message.to_owned()
            };
            let detail = data
                .get("details")
                .map(|v| v.to_string())
                .unwrap_or_default();
            let detail = if let Some(token) = &self.token {
                detail.replace(token.as_str(), "[redacted]")
            } else {
                detail
            };
            bail!(
                "HTTP {status}: {} {}",
                crate::paths::terminal(&message),
                crate::paths::terminal(&detail)
            );
        }
        Ok(response)
    }
    pub fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, &str)]) -> Result<T> {
        let mut request = self.agent.get(self.url(path, query)?.as_str());
        if let Some(token) = &self.token {
            request = request.header("Authorization", format!("Bearer {}", token.as_str()));
        }
        let response = request
            .call()
            .context("Network request failed (no automatic retry)")?;
        self.decode(response)
    }
    pub fn post<T: DeserializeOwned>(&self, path: &str, data: &Value) -> Result<T> {
        let mut request = self.agent.post(self.url(path, &[])?.as_str());
        if let Some(token) = &self.token {
            request = request.header("Authorization", format!("Bearer {}", token.as_str()));
        }
        self.decode(
            request
                .send_json(data)
                .context("Network write failed; do not assume the server rejected it")?,
        )
    }
    pub fn patch<T: DeserializeOwned>(&self, path: &str, data: &Value) -> Result<T> {
        let mut request = self.agent.patch(self.url(path, &[])?.as_str());
        if let Some(token) = &self.token {
            request = request.header("Authorization", format!("Bearer {}", token.as_str()));
        }
        self.decode(
            request
                .send_json(data)
                .context("Network write failed; do not assume the server rejected it")?,
        )
    }
    pub fn upload<T: DeserializeOwned>(&self, path: &str, file: cap_std::fs::File) -> Result<T> {
        let length = file.metadata()?.len();
        let mut request = self
            .agent
            .post(self.url(path, &[])?.as_str())
            .header("Content-Type", "application/json")
            .header("Content-Length", length.to_string());
        if let Some(token) = &self.token {
            request = request.header("Authorization", format!("Bearer {}", token.as_str()));
        }
        self.decode(
            request
                .send(file.into_std())
                .context("Push response was lost; rerun push to retry the same durable request")?,
        )
    }
    fn decode<T: DeserializeOwned>(&self, response: ureq::http::Response<ureq::Body>) -> Result<T> {
        let mut response = self.checked(response)?;
        let mut bytes = Vec::new();
        response
            .body_mut()
            .as_reader()
            .take(META_LIMIT + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= META_LIMIT,
            "Server JSON exceeds 32 MiB"
        );
        serde_json::from_slice(&bytes).context("Invalid server response")
    }
    pub fn download(
        &self,
        repo: &str,
        revision: &str,
        path: &str,
        out: &mut impl Write,
    ) -> Result<u64> {
        let url = self.url(
            &format!("/repositories/{repo}/file"),
            &[("revision", revision), ("path", path), ("raw", "true")],
        )?;
        let mut request = self.agent.get(url.as_str());
        if let Some(token) = &self.token {
            request = request.header("Authorization", format!("Bearer {}", token.as_str()));
        }
        let mut response = self.checked(request.call().context("File download failed")?)?;
        let count = std::io::copy(
            &mut response.body_mut().as_reader().take(FILE_LIMIT + 1),
            out,
        )?;
        ensure!(count <= FILE_LIMIT, "File exceeds 100 MiB");
        Ok(count)
    }
}
