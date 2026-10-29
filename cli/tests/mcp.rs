use fsc::{mcp, remote::Remote};
use serde_json::{Value, json};
use std::{
    io::{Cursor, Read, Write},
    net::TcpListener,
    thread,
};

fn initialize() -> Value {
    json!({
        "jsonrpc":"2.0",
        "id":"init",
        "method":"initialize",
        "params":{
            "protocolVersion":"2025-11-25",
            "clientInfo":{"name":"fixture","version":"1"},
            "capabilities":{}
        }
    })
}

fn exchange(messages: &[Value], allow_writes: bool) -> Vec<Value> {
    exchange_with(
        Remote::new("http://127.0.0.1:4040", None).unwrap(),
        messages,
        allow_writes,
    )
}

fn exchange_with(remote: Remote, messages: &[Value], allow_writes: bool) -> Vec<Value> {
    let mut input = messages
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
    input.push('\n');
    let mut output = Vec::new();
    mcp::run(remote, allow_writes, Cursor::new(input), &mut output).unwrap();
    String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

#[test]
fn read_tools_use_fixed_routes_and_mark_server_values_untrusted() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = Vec::new();
        let mut byte = [0];
        while stream.read(&mut byte).unwrap() > 0 {
            request.push(byte[0]);
            if request.ends_with(b"\r\n\r\n") {
                break;
            }
        }
        let request = String::from_utf8(request).unwrap();
        assert!(request.starts_with("GET /api/repositories HTTP/1.1\r\n"));
        let body = r#"{"repositories":[{"id":"fixture","name":"untrusted"}]}"#;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let responses = exchange_with(
        Remote::new(&origin, None).unwrap(),
        &[
            initialize(),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_repositories","arguments":{}}}),
        ],
        false,
    );
    server.join().unwrap();

    assert_eq!(responses[1]["result"]["isError"], false);
    assert_eq!(
        responses[1]["result"]["structuredContent"]["repositories"][0]["name"],
        "untrusted"
    );
    assert_eq!(
        responses[1]["result"]["_meta"]["flurry/untrustedData"],
        true
    );
}

#[test]
fn negotiates_the_protocol_and_ignores_notifications() {
    let responses = exchange(
        &[
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"fixture","version":"1"},"capabilities":{}}}),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":2,"method":"ping"}),
        ],
        false,
    );
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0]["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(responses[0]["result"]["serverInfo"]["name"], "flurry");
    assert_eq!(responses[1], json!({"jsonrpc":"2.0","id":2,"result":{}}));
}

#[test]
fn write_tools_require_an_explicit_server_flag() {
    let list = |allow_writes| {
        exchange(
            &[
                initialize(),
                json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
                json!({"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}),
            ],
            allow_writes,
        )
        .pop()
        .unwrap()
    };
    let read_only = list(false);
    let read_names = read_only["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(read_names.len(), 7);
    assert!(!read_names.contains(&"comment_on_review"));
    assert!(
        read_only["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .all(|tool| tool["annotations"]["readOnlyHint"] == true)
    );

    let writable = list(true);
    let tools = writable["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 13);
    assert!(tools.iter().any(|tool| {
        tool["name"] == "comment_on_review"
            && tool["annotations"]["readOnlyHint"] == false
            && tool["annotations"]["destructiveHint"] == false
    }));
    assert!(
        tools
            .iter()
            .any(|tool| tool["name"] == "publish_review_finding")
    );
    assert!(
        tools
            .iter()
            .any(|tool| tool["name"] == "verify_review_finding")
    );
}

#[test]
fn disabled_writes_and_invalid_identifiers_never_reach_the_network() {
    let repository = uuid::Uuid::new_v4().to_string();
    let review = uuid::Uuid::new_v4().to_string();
    let responses = exchange(
        &[
            initialize(),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"comment_on_review","arguments":{"repository":repository,"review":review,"body":"hello"}}}),
            json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repository","arguments":{"repository":"../../settings"}}}),
        ],
        false,
    );
    assert_eq!(responses[1]["result"]["isError"], true);
    assert_eq!(
        responses[1]["result"]["content"][0]["text"],
        "MCP writes are disabled"
    );
    assert_eq!(responses[2]["result"]["isError"], true);
    assert!(
        responses[2]["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Invalid UUID")
    );
}

#[test]
fn malformed_and_oversized_messages_are_bounded() {
    let remote = Remote::new("http://127.0.0.1:4040", None).unwrap();
    let mut output = Vec::new();
    mcp::run(remote, false, Cursor::new("{\n"), &mut output).unwrap();
    let response: Value = serde_json::from_slice(&output).unwrap();
    assert_eq!(response["error"]["code"], -32700);

    let remote = Remote::new("http://127.0.0.1:4040", None).unwrap();
    let oversized = vec![b'x'; 1024 * 1024 + 2];
    assert!(mcp::run(remote, false, Cursor::new(oversized), Vec::new()).is_err());
}

#[test]
fn tools_are_unavailable_before_initialization_finishes() {
    let responses = exchange(
        &[json!({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})],
        false,
    );
    assert_eq!(responses[0]["error"]["code"], -32002);
}
