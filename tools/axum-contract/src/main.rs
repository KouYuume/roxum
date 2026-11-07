//! The routes of `tools/axum-contract/app.roc`, in axum. `compare.py` sends both
//! the same requests.
use axum::{
    extract::{DefaultBodyLimit, Form, Multipart, Path, Query},
    http::{header, HeaderValue, Method, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Redirect, Response},
    routing::{delete, get, post},
    Json, Router,
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tower_http::compression::CompressionLayer;

#[derive(Deserialize, Serialize)]
struct Item {
    name: String,
}

#[derive(Deserialize)]
struct Search {
    q: String,
    page: Option<u64>,
}

async fn marked(request: axum::extract::Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert("x-layer", HeaderValue::from_static("outer"));
    response
}

async fn nested_marked(request: axum::extract::Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert("x-nested", HeaderValue::from_static("yes"));
    response
}

async fn refuse(_request: axum::extract::Request, _next: Next) -> Response {
    StatusCode::FORBIDDEN.into_response()
}

async fn text() -> &'static str {
    "hello"
}

async fn read_json(Json(item): Json<Item>) -> String {
    item.name
}

async fn reply_json() -> Json<Item> {
    Json(Item { name: "a".into() })
}

async fn query(Query(search): Query<Search>) -> String {
    format!("{} {}", search.q, search.page.map_or("-".into(), |page| page.to_string()))
}

async fn form(Form(item): Form<Item>) -> String {
    item.name
}

async fn upload(mut form: Multipart) -> Result<String, StatusCode> {
    while let Some(field) = form.next_field().await.map_err(|_| StatusCode::BAD_REQUEST)? {
        if field.name() == Some("name") {
            return field.text().await.map_err(|_| StatusCode::BAD_REQUEST);
        }
    }
    Err(StatusCode::UNPROCESSABLE_ENTITY)
}

async fn item(Path(id): Path<u64>) -> String {
    id.to_string()
}

async fn word(Path(word): Path<String>) -> String {
    word
}

async fn rest(Path(tail): Path<String>) -> String {
    tail
}

async fn length(body: Bytes) -> String {
    body.len().to_string()
}

async fn sized(Path(size): Path<usize>) -> ([(header::HeaderName, &'static str); 1], String) {
    ([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], "x".repeat(size))
}

async fn method_name(method: Method) -> String {
    method.to_string()
}

async fn created() -> StatusCode {
    StatusCode::CREATED
}

async fn root_fallback() -> (StatusCode, &'static str) {
    (StatusCode::NOT_FOUND, "root fallback")
}

async fn nested_fallback() -> (StatusCode, &'static str) {
    (StatusCode::NOT_FOUND, "nested fallback")
}

#[tokio::main]
async fn main() {
    let nested = Router::new()
        .route("/items/{id}", get(item))
        .layer(middleware::from_fn(nested_marked))
        .fallback(nested_fallback);

    let plain_fallback_free = Router::new()
        .route("/items/{id}", get(item));

    let app = Router::new()
        .route("/before", get(text))
        .layer(middleware::from_fn(marked))
        .route("/text", get(text))
        .route("/json", post(read_json))
        .route("/json-reply", get(reply_json))
        .route("/query", get(query))
        .route("/form", post(form))
        .route("/upload", post(upload))
        .route("/items/{id}", get(item))
        .route("/words/{word}", get(word))
        .route("/rest/{*tail}", get(rest))
        .route("/limited", post(length).layer(DefaultBodyLimit::max(1024)))
        .route("/created", get(created))
        .route("/see-other", get(|| async { Redirect::to("/done") }))
        .route("/temporary", get(|| async { Redirect::temporary("/done") }))
        .route("/permanent", get(|| async { Redirect::permanent("/done") }))
        .route("/methods", get(method_name).delete(method_name))
        .route("/delete-only", delete(method_name))
        .route("/refused", get(text).layer(middleware::from_fn(refuse)))
        .route("/sized/{size}", get(sized).layer(CompressionLayer::new()))
        .nest("/api", nested)
        .nest("/plain", plain_fallback_free)
        .fallback(root_fallback);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    println!("{}", listener.local_addr().unwrap().port());
    axum::serve(listener, app).await.unwrap();
}
