//! The comparison server: the same routes as ../app.roc.
use axum::{body::Bytes, extract::Path, http::header, response::IntoResponse, routing::{get, post}, Router};

async fn plaintext() -> &'static str {
    "Hello, World!"
}

async fn json() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "application/json")], "{\"message\":\"Hello, World!\"}")
}

async fn item(Path(id): Path<String>) -> String {
    id
}

async fn echo(body: Bytes) -> Bytes {
    body
}

#[tokio::main]
async fn main() {
    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json))
        .route("/echo", post(echo));
    // 100 routes that differ in their first segment.
    for index in 0..100 {
        app = app.route(&format!("/r{index}/items/{{id}}"), get(item));
    }
    let address = match std::fs::read("benchmark-remote") {
        Ok(bytes) if bytes == b"enabled\n" => "0.0.0.0:8080",
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => "127.0.0.1:0",
        _ => panic!("benchmark-remote must contain enabled followed by a newline"),
    };
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    println!("{}", listener.local_addr().unwrap().port());
    axum::serve(listener, app).await.unwrap();
}
