//! The comparison server: the same routes as ../app.roc.
use axum::{
    body::Bytes,
    extract::Path,
    http::header,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use axum::{
    extract::{Extension, Request},
    http::{HeaderValue, StatusCode},
    middleware::{self, Next},
    response::Response,
    Json,
};
use tower_http::services::ServeFile;

async fn plaintext() -> &'static str {
    "Hello, World!"
}

async fn json() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "application/json")],
        "{\"message\":\"Hello, World!\"}",
    )
}

async fn item(Path(id): Path<String>) -> String {
    id
}

async fn source_layer(mut request: Request, next: Next) -> Result<Response, StatusCode> {
    let source = request
        .headers()
        .get("x-bench-source")
        .and_then(|value| value.to_str().ok())
        .ok_or(StatusCode::BAD_REQUEST)?
        .to_owned();
    request.extensions_mut().insert(source);
    let mut response = next.run(request).await;
    response
        .headers_mut()
        .insert("x-bench-layer", HeaderValue::from_static("active"));
    Ok(response)
}

async fn dynamic(
    Path(id): Path<String>,
    Extension(source): Extension<String>,
) -> Json<[String; 2]> {
    Json([id, source])
}

async fn echo(body: Bytes) -> Bytes {
    body
}

#[tokio::main]
async fn main() {
    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json))
        .route("/echo", post(echo))
        .route(
            "/dynamic/{id}",
            get(dynamic).route_layer(middleware::from_fn(source_layer)),
        )
        .route_service("/file-64k", ServeFile::new("bench-payload.bin"));
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
