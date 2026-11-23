use std::error::Error;
use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;

use serde::Deserialize;
use warp::Filter;

use crate::state::SharedState;

#[derive(Deserialize)]
struct StateQuery {
    minutes: Option<u32>,
}

pub fn bind(
    shared: Arc<SharedState>,
    port: u16,
) -> Result<(SocketAddr, impl Future<Output = ()> + Send + 'static), Box<dyn Error>> {
    let root = warp::path::end()
        .and(warp::get())
        .map(|| html(include_str!("../web/index.html")));

    let overlay = warp::path("overlay")
        .and(warp::path::end())
        .and(warp::get())
        .map(|| html(include_str!("../web/overlay.html")));

    let state_shared = shared.clone();
    let state = warp::path!("api" / "state")
        .and(warp::get())
        .and(warp::query::<StateQuery>())
        .map(move |query: StateQuery| {
            let snapshot = state_shared.snapshot(query.minutes.unwrap_or(10));
            let body = serde_json::to_vec(&snapshot).unwrap_or_else(|_| b"{}".to_vec());
            warp::reply::with_header(
                warp::reply::with_header(body, "content-type", "application/json; charset=utf-8"),
                "cache-control",
                "no-store",
            )
        });

    let export_shared = shared.clone();
    let export = warp::path!("api" / "export.csv")
        .and(warp::get())
        .map(move || {
            let bytes = export_shared.csv_bytes();
            let path = export_shared.csv_path();
            let filename = path
                .rsplit('/')
                .next()
                .unwrap_or("heart-rate.csv")
                .to_string();
            warp::reply::with_header(
                warp::reply::with_header(bytes, "content-type", "text/csv; charset=utf-8"),
                "content-disposition",
                format!("attachment; filename=\"{filename}\""),
            )
        });

    let health = warp::path!("api" / "health")
        .and(warp::get())
        .map(|| warp::reply::json(&serde_json::json!({ "ok": true })));

    let favicon = warp::path("favicon.ico")
        .and(warp::get())
        .map(|| warp::reply::with_status("", warp::http::StatusCode::NO_CONTENT));

    let routes = root
        .or(overlay)
        .or(state)
        .or(export)
        .or(health)
        .or(favicon)
        .with(warp::reply::with::header(
            "x-content-type-options",
            "nosniff",
        ))
        .with(warp::reply::with::header(
            "content-security-policy",
            "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'",
        ));

    let (address, server) = warp::serve(routes).try_bind_ephemeral(([127, 0, 0, 1], port))?;
    Ok((address, server))
}

fn html(body: &'static str) -> impl warp::Reply {
    warp::reply::with_header(
        warp::reply::with_header(
            warp::reply::html(body),
            "content-type",
            "text/html; charset=utf-8",
        ),
        "cache-control",
        "no-store",
    )
}
