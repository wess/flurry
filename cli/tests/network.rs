use fsc::remote::Remote;
use std::{
    io::{Read, Write},
    net::TcpListener,
    thread,
};
use zeroize::Zeroizing;
fn server(status: &str, headers: &str, body: &str) -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
        body.len()
    );
    let task = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = Vec::new();
        let mut byte = [0];
        while stream.read(&mut byte).unwrap() > 0 {
            request.push(byte[0]);
            if request.ends_with(b"\r\n\r\n") {
                break;
            }
        }
        stream.write_all(response.as_bytes()).unwrap();
        String::from_utf8(request).unwrap()
    });
    (origin, task)
}
#[test]
fn redirects_never_forward_credentials() {
    let trap = TcpListener::bind("127.0.0.1:0").unwrap();
    trap.set_nonblocking(true).unwrap();
    let (origin, task) = server(
        "302 Found",
        &format!("Location: http://{}/steal\r\n", trap.local_addr().unwrap()),
        "",
    );
    let remote = Remote::new(&origin, Some(Zeroizing::new("fixturesecret".into()))).unwrap();
    assert!(
        remote
            .get::<serde_json::Value>("/repositories", &[])
            .is_err()
    );
    assert!(task.join().unwrap().contains("Bearer fixturesecret"));
    assert!(trap.accept().is_err());
}
#[test]
fn server_errors_redact_credentials_and_escape_terminal_controls() {
    let (origin, task) = server(
        "403 Forbidden",
        "Content-Type: application/json\r\n",
        r#"{"error":"fixturesecret\u001b[2J","details":{"token":"fixturesecret"}}"#,
    );
    let remote = Remote::new(&origin, Some(Zeroizing::new("fixturesecret".into()))).unwrap();
    let error = remote
        .get::<serde_json::Value>("/repositories", &[])
        .unwrap_err()
        .to_string();
    assert!(!error.contains("fixturesecret"));
    assert!(!error.contains('\u{1b}'));
    assert!(error.contains("redacted"));
    task.join().unwrap();
}
#[test]
fn malformed_server_json_returns_an_error() {
    let (origin, task) = server("200 OK", "Content-Type: application/json\r\n", "[");
    let remote = Remote::new(&origin, None).unwrap();
    assert!(
        remote
            .get::<serde_json::Value>("/repositories", &[])
            .is_err()
    );
    task.join().unwrap();
}

#[test]
fn ambiguous_push_retries_reuse_the_identical_durable_request() {
    use fsc::{
        disk::Disk,
        model::{Branch, Commit, State},
    };
    use std::collections::BTreeMap;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = thread::spawn(move || {
        let read_request = |stream: &mut std::net::TcpStream| {
            let mut headers = Vec::new();
            let mut byte = [0];
            while stream.read(&mut byte).unwrap() > 0 {
                headers.push(byte[0]);
                if headers.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            let headers = String::from_utf8(headers).unwrap();
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length: ")
                        .map(str::to_owned)
                })
                .unwrap()
                .parse::<usize>()
                .unwrap();
            assert!(length < 16384);
            let mut body = vec![0; length];
            stream.read_exact(&mut body).unwrap();
            body
        };
        let (mut first, _) = listener.accept().unwrap();
        let first_body = read_request(&mut first);
        drop(first);
        let (mut second, _) = listener.accept().unwrap();
        let second_body = read_request(&mut second);
        assert_eq!(first_body, second_body);
        let request: serde_json::Value = serde_json::from_slice(&second_body).unwrap();
        let id = request["commits"][0]["id"].as_str().unwrap();
        assert_eq!(request["commits"][0]["files"][0]["base64"], "Y29udGVudA==");
        let body=serde_json::json!({"head":"b".repeat(64),"branch":"main","commits":{id:"b".repeat(64)},"review_id":uuid::Uuid::new_v4().to_string(),"protected":true}).to_string();
        write!(second,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
    });
    let directory = tempfile::tempdir().unwrap();
    let disk = Disk::open(directory.path(), true).unwrap();
    let (hash, _) = disk.store("content".as_bytes(), None).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let mut state = State {
        version: 1,
        server: origin.clone(),
        repository: uuid::Uuid::new_v4().to_string(),
        current: "main".into(),
        prefix: String::new(),
        branches: BTreeMap::from([(
            "main".into(),
            Branch {
                head: Some(id.clone()),
                upstream: None,
                review: None,
            },
        )]),
        remotes: BTreeMap::new(),
        tags: BTreeMap::new(),
        annotations: BTreeMap::new(),
        commits: BTreeMap::from([(
            id.clone(),
            Commit {
                parent: None,
                merge_parent: None,
                message: "Commit".into(),
                files: BTreeMap::from([("a".into(), hash)]).into(),
                git: None,
            },
        )]),
        index: BTreeMap::new(),
    };
    disk.save("state.json", &state).unwrap();
    let remote = Remote::new(&origin, None).unwrap();
    assert!(fsc::push::push(&disk, &mut state, &remote, false).is_err());
    assert!(disk.meta.symlink_metadata("push.json").is_ok());
    assert_eq!(state.head(), Some(id.as_str()));
    fsc::push::push(&disk, &mut state, &remote, false).unwrap();
    assert_eq!(state.head(), Some("b".repeat(64).as_str()));
    assert!(disk.meta.symlink_metadata("push.json").is_err());
    task.join().unwrap();
}

#[test]
fn local_and_remote_merge_bases_are_checked_together_before_resolving_history() {
    use fsc::model::{Branch, Commit, State};
    use std::{
        collections::BTreeMap,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        time::Duration,
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let done = Arc::new(AtomicBool::new(false));
    let finished = done.clone();
    let root = "1".repeat(64);
    let shared_remote = "2".repeat(64);
    let f = "3".repeat(64);
    let g = "4".repeat(64);
    let shared_local = uuid::Uuid::new_v4().to_string();
    let left = uuid::Uuid::new_v4().to_string();
    let right = uuid::Uuid::new_v4().to_string();
    let server_root = root.clone();
    let server_shared = shared_remote.clone();
    let task = thread::spawn(move || {
        while !finished.load(Ordering::SeqCst) {
            let (mut stream, _) = match listener.accept() {
                Ok(connection) => connection,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(1));
                    continue;
                }
                Err(error) => panic!("{error}"),
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut byte = [0];
            while stream.read(&mut byte).unwrap() > 0 {
                bytes.push(byte[0]);
                if bytes.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            let request = String::from_utf8(bytes).unwrap();
            let path = request
                .lines()
                .next()
                .unwrap()
                .split_whitespace()
                .nth(1)
                .unwrap();
            let url = url::Url::parse(&format!("http://fixture{path}")).unwrap();
            let query = url.query_pairs().into_owned().collect::<BTreeMap<_, _>>();
            let response = if url.path().ends_with("mergebase") {
                let base = if query["left"] == server_root || query["right"] == server_root {
                    &server_root
                } else {
                    &server_shared
                };
                serde_json::json!({"base":base})
            } else {
                let a = &query["ancestor"];
                let b = &query["descendant"];
                serde_json::json!({"ancestor":a==b || *a==server_root || (*a==server_shared && ["2".repeat(64),"3".repeat(64),"4".repeat(64)].contains(b))})
            };
            let body = response.to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        }
    });
    let commit = |parent: Option<String>, merge_parent: Option<String>| Commit {
        parent,
        merge_parent,
        message: "Merge fixture".into(),
        files: BTreeMap::new().into(),
        git: None,
    };
    let state = State {
        version: 1,
        server: origin.clone(),
        repository: uuid::Uuid::new_v4().to_string(),
        current: "main".into(),
        prefix: String::new(),
        branches: BTreeMap::from([(
            "main".into(),
            Branch {
                head: Some(left.clone()),
                upstream: Some(root.clone()),
                review: None,
            },
        )]),
        remotes: BTreeMap::new(),
        tags: BTreeMap::new(),
        annotations: BTreeMap::new(),
        commits: BTreeMap::from([
            (shared_local.clone(), commit(Some(root), None)),
            (left.clone(), commit(Some(shared_local.clone()), Some(f))),
            (right.clone(), commit(Some(shared_local), Some(g))),
        ]),
        index: BTreeMap::new(),
    };
    let result = fsc::graph::base(
        &state,
        &Remote::new(&origin, None).unwrap(),
        Some(&left),
        Some(&right),
    );
    done.store(true, Ordering::SeqCst);
    task.join().unwrap();
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("Multiple merge bases")
    );
}
