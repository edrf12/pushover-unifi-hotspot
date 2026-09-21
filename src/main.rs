use axum::{
    Form, Json, Router,
    extract::{Query, State},
    http::{StatusCode, header},
    response::{
        Html, Redirect,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{get, post},
};
use axum_client_ip::{ClientIp, ClientIpSource};
use axum_extra::routing::RouterExt;
use clap::Parser;
use futures_util::{Stream, stream};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    convert::Infallible,
    net::IpAddr,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, watch};
use uuid::Uuid;

type AppError = (StatusCode, &'static str);
const APPROVAL_WINDOW: Duration = Duration::from_secs(90);
const SESSION_RETENTION: Duration = Duration::from_secs(900);

#[derive(Clone)]
struct AppState {
    config: Arc<Config>,
    client: reqwest::Client,
    sessions: Arc<Mutex<HashMap<String, ClientSession>>>,
}

#[derive(Parser)]
struct Config {
    /// URL for the application.
    #[arg(long, env = "APPLICATION_URL", hide_env_values = false)]
    application_url: String,

    /// API key for talking to the UniFi controller.
    /// You may get this from the UniFi site manager or the controller's API key management page.
    #[arg(long, env = "UNIFI_API_KEY", hide_env_values = true)]
    unifi_api_key: String,

    /// URL for the UniFi controller's API.
    /// Either https://api.ui.com/v1/connector/consoles/<console_id> or https://<controller_ip>/
    #[arg(long, env = "UNIFI_API_URL", hide_env_values = false)]
    unifi_api_url: String,

    /// Site ID for the UniFi site.
    /// You can find this by making this request `curl -X GET "$UNIFI_API_URL/integration/v1/sites" -H "X-API-Key: $UNIFI_API_KEY"`
    #[arg(long, env = "UNIFI_SITE_ID", hide_env_values = false)]
    unifi_site_id: String,

    /// Legacy site name, which differs from the integration API's site UUID.
    /// In most cases you won't need to change this.
    #[arg(long, env = "UNIFI_LEGACY_SITE_NAME", default_value = "default")]
    unifi_legacy_site_name: String,

    /// Pushover token for sending notifications.
    #[arg(long, env = "PUSHOVER_TOKEN", hide_env_values = true)]
    pushover_token: String,

    /// Pushover user for sending notifications.
    #[arg(long, env = "PUSHOVER_USER", hide_env_values = true)]
    pushover_user: String,
}

// Wired guests don't return SSID
fn ssid_default() -> String {
    "Wired".to_string()
}

#[derive(Debug, Deserialize)]
struct UnifiGuestParams {
    id: String,
    #[serde(default = "ssid_default")]
    ssid: String,
}

#[derive(Debug, Deserialize)]
struct UnifiClientResponse {
    data: Vec<UnifiClient>,
}

#[derive(Debug, Deserialize)]
struct UnifiClient {
    id: String,
    name: String,
    #[serde(rename = "macAddress")]
    mac_address: Option<String>,
    access: UnifiClientAccess,
}

#[derive(Deserialize)]
struct LegacyClientResponse {
    data: Vec<LegacyClient>,
}

#[derive(Debug, Deserialize)]
struct LegacyClient {
    mac: String,
    #[serde(default)]
    ipv6_addresses: Option<Vec<IpAddr>>,
    #[serde(default)]
    essid: Option<String>,
    #[serde(default)]
    is_wired: bool,
}

#[derive(Debug, Deserialize)]
struct UnifiClientAccess {
    authorized: bool,
}

struct ClientSession {
    receipt: Option<String>,
    authorizing_until: Option<Instant>,
    browser_token: String,
    approval_started: Instant,
    retained_since: Instant,
    updates: watch::Sender<ApprovalUpdate>,
}

#[derive(Clone, Debug, PartialEq)]
enum ApprovalUpdate {
    Waiting(Instant),
    Authorized,
    Expired,
    Failed,
}

impl ClientSession {
    /// Returns whether another portal request should reuse this session.
    ///
    /// Authorized sessions remain reusable if UniFi briefly reports stale state. An
    /// active authorization attempt extends a waiting session beyond its approval window.
    fn can_reuse(&self) -> bool {
        match self.updates.borrow().clone() {
            ApprovalUpdate::Authorized => return true,
            ApprovalUpdate::Failed | ApprovalUpdate::Expired => return false,
            ApprovalUpdate::Waiting(_) => {}
        }
        if self
            .authorizing_until
            .is_some_and(|until| until > Instant::now())
        {
            return true;
        }
        self.approval_started.elapsed() < APPROVAL_WINDOW
    }
}

#[derive(Deserialize)]
struct PushoverCallbackParams {
    receipt: String,
    acknowledged: String,
}

#[derive(Deserialize)]
struct PushoverResponse {
    status: u8,
    receipt: String,
}

#[derive(Deserialize)]
struct BrowserSession {
    session: String,
    id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "kebab-case")]
struct CapportStatus {
    captive: bool,
    user_portal_url: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthorizationRequest {
    action: &'static str,
}

enum SessionStart {
    Send(String),
    Waiting(String),
}

/*
 *
 * Unifi URLs
 *
 */

/// Builds the modern connected-clients endpoint from the connector-console base URL.
fn integration_clients_url(config: &Config) -> String {
    format!(
        "{}/proxy/network/integration/v1/sites/{}/clients",
        config.unifi_api_url.trim_end_matches('/'),
        config.unifi_site_id
    )
}

/// Builds the legacy connected-clients endpoint from the connector-console base URL.
fn legacy_clients_url(config: &Config) -> String {
    format!(
        "{}/proxy/network/api/s/{}/stat/sta",
        config.unifi_api_url.trim_end_matches('/'),
        config.unifi_legacy_site_name
    )
}

#[tokio::main]
async fn main() {
    let config = Arc::new(Config::parse());
    let state = AppState {
        config,
        sessions: Arc::new(Mutex::new(HashMap::new())),
        client: reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client"),
    };

    tokio::spawn(cleanup_sessions(state.clone()));

    let app = Router::new()
        // Frontend routes
        .route(
            "/",
            get(|| async { Html(include_str!("pages/status.html")) }),
        )
        .route(
            "/waiting",
            get(|| async { Html(include_str!("pages/waiting.html")) }),
        )
        .route(
            "/authorized",
            get(|| async { Html(include_str!("pages/authorized.html")) }),
        )
        // Unifi initiator route
        .route_with_tsr("/guest/s/default/", get(unifi_guest))
        // Capport (IPv6 support)
        .route("/capport", get(capport))
        // Guest SSE
        .route("/guest/events", get(guest_events))
        // Pushover callback
        .route_with_tsr("/guest/callback", post(pushover_callback))
        .layer(ClientIpSource::XRealIp.into_extension())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/*
 *
 * Routes
 *
 */

/// Starts or reuses guest approval and redirects the browser to the appropriate page.
///
/// Already-authorized clients go directly to the authorized page. Other clients are redirected to the waiting page as soon as their session is reserved. A background task sends the Pushover notification and stores its receipt.
///
/// # Errors
/// Returns client lookup errors.
async fn unifi_guest(
    State(state): State<AppState>,
    Query(params): Query<UnifiGuestParams>,
) -> Result<Redirect, AppError> {
    let client = find_client(&state, &params.id).await?;

    if client.access.authorized {
        return Ok(Redirect::to("/authorized"));
    }

    let token = match reserve_session(&state, &client.id).await {
        SessionStart::Send(token) => token,
        SessionStart::Waiting(token) => {
            return Ok(waiting_redirect(&token, &params.id));
        }
    };

    let redirect = waiting_redirect(&token, &params.id);
    tokio::spawn(async move {
        let result = send_pushover_notification(&state, &client.name, &params.ssid).await;
        if let Err((_, message)) = finish_notification(&state, &client.id, &token, result).await {
            eprintln!("Background notification failed: {message}");
        }
    });
    Ok(redirect)
}

/// Returns the requesting client's captive state in the RFC 8908 format.
///
/// Reads the client address supplied by the reverse proxy in `X-Real-IP`. IPv6
/// clients use a fresh legacy UniFi client response to obtain the MAC used for the
/// integration lookup.
///
/// # Errors
/// Returns an error for a missing client MAC address, an insecure application
/// URL, or a failed UniFi lookup.
async fn capport(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
) -> Result<impl axum::response::IntoResponse, AppError> {
    let legacy = fetch_legacy_clients(&state).await?;
    let client = match ip {
        IpAddr::V4(_) => find_client_by_filter(&state, "ipAddress", &ip.to_string()).await?,
        IpAddr::V6(_) => {
            let mac = legacy_client_mac(&legacy, ip)?;
            find_client(&state, &mac).await?
        }
    };
    let mac = client
        .mac_address
        .as_deref()
        .ok_or((StatusCode::BAD_GATEWAY, "UniFi client has no MAC address"))?;
    let portal_url = capport_portal_url(
        &state.config.application_url,
        mac,
        legacy_ssid(&legacy, mac),
    )?;

    Ok((
        [
            (
                header::CONTENT_TYPE,
                header::HeaderValue::from_static("application/captive+json"),
            ),
            (
                header::CACHE_CONTROL,
                header::HeaderValue::from_static("no-store"),
            ),
        ],
        Json(CapportStatus {
            captive: !client.access.authorized,
            user_portal_url: portal_url,
        }),
    ))
}

/// Serves approval events for a browser session with 15-second keep-alives.
///
/// If the session is absent, checks the supplied client MAC with UniFi once to recover authorization status without creating a notification. Requests that proxies disable response buffering.
///
/// # Errors
/// Propagates client lookup failures when recovering an absent session.
async fn guest_events(
    State(state): State<AppState>,
    Query(query): Query<BrowserSession>,
) -> Result<impl axum::response::IntoResponse, AppError> {
    let receiver = {
        let sessions = state.sessions.lock().await;
        sessions
            .values()
            .find(|s| s.browser_token == query.session)
            .map(|s| s.updates.subscribe())
    };
    let receiver = match receiver {
        Some(receiver) => receiver,
        None => {
            // Recover browsers after session retention ends from UniFi, which remains the
            // source of truth. This never sends a notification.
            let client = find_client(&state, &query.id).await?;
            let status = if client.access.authorized {
                ApprovalUpdate::Authorized
            } else {
                ApprovalUpdate::Expired
            };
            watch::channel(status).1
        }
    };
    Ok((
        [(
            axum::http::header::HeaderName::from_static("x-accel-buffering"),
            "no",
        )],
        Sse::new(approval_events(receiver))
            .keep_alive(KeepAlive::new().interval(Duration::from_secs(15))),
    ))
}

/// Handles a Pushover acknowledgment using its receipt to locate the client.
///
/// Matches the secret receipt to a pending session, performs authorization, then updates the session and notifies subscribers.
///
/// # Errors
/// Rejects callbacks without acknowledgment and propagates receipt, reservation,
/// or authorization failures.
async fn pushover_callback(
    State(state): State<AppState>,
    Form(params): Form<PushoverCallbackParams>,
) -> Result<(), AppError> {
    if params.acknowledged != "1" {
        return Err((StatusCode::BAD_REQUEST, "Notification is not acknowledged"));
    }
    let client_id = begin_authorization(&state, &params.receipt).await?;
    let result = authorize_client(&state, &client_id).await;
    finish_authorization(&state, &client_id, &params.receipt, result.is_ok()).await;
    result
}

/*
 *
 * Utils
 *
 */

/// Sends an emergency Pushover notification and returns its callback receipt.
///
/// # Errors
/// Returns HTTP 502 when Pushover cannot be reached, rejects the request, or omits a receipt.
async fn send_pushover_notification(
    state: &AppState,
    client_name: &str,
    ssid: &str,
) -> Result<String, AppError> {
    let pushover_message = format!("{client_name} is trying to connect to {ssid}");
    let pushover_callback_url = format!(
        "{}/guest/callback",
        state.config.application_url.trim_end_matches('/')
    );
    let pushover_params = [
        ("token", state.config.pushover_token.as_str()),
        ("user", state.config.pushover_user.as_str()),
        ("message", pushover_message.as_str()),
        ("priority", "2"),
        ("expire", "90"),
        ("retry", "30"),
        ("sound", "siren"),
        ("callback", pushover_callback_url.as_str()),
    ];

    let response = state
        .client
        .post("https://api.pushover.net/1/messages.json")
        .form(&pushover_params)
        .send()
        .await
        .map_err(upstream_error)?
        .error_for_status()
        .map_err(upstream_error)?
        .json::<PushoverResponse>()
        .await
        .map_err(upstream_error)?;
    if response.status != 1 || response.receipt.is_empty() {
        return Err((StatusCode::BAD_GATEWAY, "Pushover did not return a receipt"));
    }
    Ok(response.receipt)
}

/// Reuses a pending client session or reserves a new one before sending a notification.
///
/// Checks and insertion share one map lock so concurrent requests cannot both send.
/// Expired sessions are replaced, and entries past the retention period are removed.
async fn reserve_session(state: &AppState, client_id: &str) -> SessionStart {
    let mut sessions = state.sessions.lock().await;
    sessions.retain(|_, s| s.retained_since.elapsed() < SESSION_RETENTION);
    if let Some(session) = sessions.get(client_id).filter(|s| s.can_reuse()) {
        return SessionStart::Waiting(session.browser_token.clone());
    }
    let token = Uuid::new_v4().to_string();
    let now = Instant::now();
    sessions.insert(
        client_id.to_owned(),
        ClientSession {
            receipt: None,
            authorizing_until: None,
            browser_token: token.clone(),
            approval_started: now,
            retained_since: now,
            updates: watch::channel(ApprovalUpdate::Waiting(now + APPROVAL_WINDOW)).0,
        },
    );
    SessionStart::Send(token)
}

/// Stores the Pushover receipt or publishes a failed notification attempt.
///
/// Updates only the session matching `token`, so a late response cannot overwrite
/// a newer attempt. Subscribers receive the refreshed deadline or a failure event.
///
/// # Errors
/// Returns the supplied notification error after updating the session.
async fn finish_notification(
    state: &AppState,
    client_id: &str,
    token: &str,
    result: Result<String, AppError>,
) -> Result<(), AppError> {
    let mut sessions = state.sessions.lock().await;
    // A late response must never overwrite a newer attempt for this client.
    if let Some(session) = sessions
        .get_mut(client_id)
        .filter(|s| s.browser_token == token)
    {
        let now = Instant::now();
        session.retained_since = now;
        match &result {
            Ok(receipt) => {
                session.receipt = Some(receipt.clone());
                session.approval_started = now;
                session
                    .updates
                    .send_replace(ApprovalUpdate::Waiting(now + APPROVAL_WINDOW));
            }
            Err(_) => {
                session.updates.send_replace(ApprovalUpdate::Failed);
            }
        }
    }
    result.map(|_| ())
}

/// Finds the client by receipt and reserves its authorization attempt.
///
/// Extends the waiting deadline while upstream requests run. The reservation expires
/// if the task is cancelled, allowing a later callback to retry.
///
/// # Errors
/// Returns HTTP 503 for an unknown receipt or an active attempt, and HTTP 410
/// when the matching session is past its retention period.
async fn begin_authorization(state: &AppState, receipt: &str) -> Result<String, AppError> {
    let mut sessions = state.sessions.lock().await;
    let (client_id, session) = sessions
        .iter_mut()
        .find(|(_, s)| s.receipt.as_deref() == Some(receipt))
        .ok_or((StatusCode::SERVICE_UNAVAILABLE, "Receipt is not available"))?;
    if session.retained_since.elapsed() >= SESSION_RETENTION {
        return Err((StatusCode::GONE, "Session expired"));
    }
    if session
        .authorizing_until
        .is_some_and(|until| until > Instant::now())
    {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "Authorization is in progress",
        ));
    }
    // Covers the UniFi request timeout and recovers if the task is cancelled.
    let deadline = Instant::now() + APPROVAL_WINDOW;
    session.authorizing_until = Some(deadline);
    session
        .updates
        .send_replace(ApprovalUpdate::Waiting(deadline));
    Ok(client_id.clone())
}

/// Publishes successful authorization and retains the session for browser reconnects.
///
/// On failure, releases the authorization reservation and restores the original
/// approval deadline. A mismatched or missing receipt leaves the map unchanged.
async fn finish_authorization(state: &AppState, client_id: &str, receipt: &str, success: bool) {
    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions
        .get_mut(client_id)
        .filter(|s| s.receipt.as_deref() == Some(receipt))
    else {
        return;
    };
    session.authorizing_until = None;
    if success {
        // Prevent repeated callbacks while retaining the browser token and terminal update.
        session.receipt = None;
        session.retained_since = Instant::now();
        session.updates.send_replace(ApprovalUpdate::Authorized);
    } else {
        session.updates.send_replace(ApprovalUpdate::Waiting(
            session.approval_started + APPROVAL_WINDOW,
        ));
    }
}

/// Streams the current approval status followed by watch-channel updates.
///
/// Emits an expiration event when the waiting deadline passes or the sender closes.
/// The stream ends after an authorized, failed, or expired event; it holds no map lock.
fn approval_events(
    rx: watch::Receiver<ApprovalUpdate>,
) -> impl Stream<Item = Result<Event, Infallible>> {
    stream::unfold((rx, true, false), |(mut rx, first, done)| async move {
        if done {
            return None;
        }
        if !first {
            let current = rx.borrow().clone();
            if let ApprovalUpdate::Waiting(deadline) = current {
                tokio::select! {
                    biased;
                    result = rx.changed() => {
                        if result.is_err() {
                            return Some((Ok(Event::default().event("expired").data("expired")), (rx, false, true)));
                        }
                    }
                    _ = tokio::time::sleep_until(deadline.into()) => {
                        return Some((Ok(Event::default().event("expired").data("expired")), (rx, false, true)));
                    }
                }
            }
        }
        let current = rx.borrow_and_update().clone();
        let (name, done) = match current {
            ApprovalUpdate::Waiting(deadline) if deadline > Instant::now() => ("waiting", false),
            ApprovalUpdate::Authorized => ("authorized", true),
            ApprovalUpdate::Failed => ("failed", true),
            _ => ("expired", true),
        };
        Some((
            Ok(Event::default().event(name).data(name)),
            (rx, false, done),
        ))
    })
}

/// Builds a relative redirect to the waiting page with encoded session and MAC parameters.
fn waiting_redirect(token: &str, mac: &str) -> Redirect {
    let mut url = reqwest::Url::parse("http://localhost/waiting").unwrap();
    url.query_pairs_mut()
        .append_pair("session", token)
        .append_pair("id", mac);
    Redirect::to(&format!("{}?{}", url.path(), url.query().unwrap()))
}

/// Removes sessions past the retention period and expires pending subscribers.
///
/// Runs every 30 seconds until the background task is cancelled.
async fn cleanup_sessions(state: AppState) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        interval.tick().await;
        let mut sessions = state.sessions.lock().await;
        sessions.retain(|_, session| {
            if session.retained_since.elapsed() >= SESSION_RETENTION {
                if matches!(*session.updates.borrow(), ApprovalUpdate::Waiting(_)) {
                    session.updates.send_replace(ApprovalUpdate::Expired);
                }
                false
            } else {
                true
            }
        });
    }
}

/// Fetches native client identities and SSIDs using the existing API key and timeout.
/// Rejects non-successful legacy API HTTP status codes.
async fn fetch_legacy_clients(state: &AppState) -> Result<Vec<LegacyClient>, AppError> {
    let response = state
        .client
        .get(legacy_clients_url(&state.config))
        .header("X-API-Key", &state.config.unifi_api_key)
        .send()
        .await
        .map_err(upstream_error)?
        .error_for_status()
        .map_err(upstream_error)?
        .json::<LegacyClientResponse>()
        .await
        .map_err(upstream_error)?;
    Ok(response.data)
}

/// Returns the client's actual Wi-Fi SSID, or a label when it is wired or unavailable.
fn legacy_ssid<'a>(clients: &'a [LegacyClient], mac: &str) -> &'a str {
    let Some(client) = clients
        .iter()
        .find(|client| client.mac.eq_ignore_ascii_case(mac))
    else {
        return "Guest Wi-Fi";
    };
    if client.is_wired {
        return "Wired";
    }
    client
        .essid
        .as_deref()
        .filter(|ssid| !ssid.is_empty())
        .unwrap_or("Guest Wi-Fi")
}

/// Matches parsed addresses, refusing conflicting identities or invalid MAC values.
fn legacy_client_mac(clients: &[LegacyClient], ip: IpAddr) -> Result<String, AppError> {
    let mut found: Option<String> = None;
    for client in clients {
        if !client
            .ipv6_addresses
            .as_ref()
            .is_some_and(|addresses| addresses.contains(&ip))
        {
            continue;
        }
        if !valid_mac(&client.mac) {
            return Err((
                StatusCode::BAD_GATEWAY,
                "UniFi returned an invalid client MAC",
            ));
        }
        let mac = client.mac.to_ascii_lowercase();
        if found.as_ref().is_some_and(|previous| previous != &mac) {
            return Err((
                StatusCode::BAD_GATEWAY,
                "UniFi returned ambiguous IPv6 client identity",
            ));
        }
        found = Some(mac);
    }
    found.ok_or((StatusCode::NOT_FOUND, "UniFi IPv6 client not found"))
}

/// Builds the HTTPS portal URL for a client identified by MAC address.
///
/// # Errors
/// Returns HTTP 500 when `APPLICATION_URL` is invalid or does not use HTTPS.
fn capport_portal_url(application_url: &str, mac: &str, ssid: &str) -> Result<String, AppError> {
    let mut url = reqwest::Url::parse(&format!(
        "{}/guest/s/default/",
        application_url.trim_end_matches('/')
    ))
    .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Invalid application URL"))?;
    if url.scheme() != "https" {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "CAPPORT requires an HTTPS application URL",
        ));
    }
    url.query_pairs_mut()
        .append_pair("id", mac)
        .append_pair("ssid", ssid);
    Ok(url.into())
}

/// Grants guest access through UniFi after the callback matches a pending receipt.
///
/// # Errors
/// Returns HTTP 502 on an upstream transport or HTTP status failure.
async fn authorize_client(state: &AppState, client_id: &str) -> Result<(), AppError> {
    state
        .client
        .post(format!(
            "{}/{}/actions",
            integration_clients_url(&state.config),
            client_id
        ))
        .header("X-API-Key", &state.config.unifi_api_key)
        .json(&AuthorizationRequest {
            action: "AUTHORIZE_GUEST_ACCESS",
        })
        .send()
        .await
        .map_err(upstream_error)?
        .error_for_status()
        .map_err(upstream_error)?;
    Ok(())
}

/// Checks a colon-separated MAC address without accepting filter syntax.
fn valid_mac(mac: &str) -> bool {
    mac.len() == 17
        && mac.split(':').count() == 6
        && mac
            .split(':')
            .all(|octet| octet.len() == 2 && octet.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

/// Fetches the first UniFi client matching the supplied MAC address.
///
/// # Errors
/// Returns HTTP 400 for an invalid MAC, HTTP 404 when no client matches, or HTTP 502 if the upstream request
/// or response decoding fails.
async fn find_client(state: &AppState, mac: &str) -> Result<UnifiClient, AppError> {
    if !valid_mac(mac) {
        return Err((StatusCode::BAD_REQUEST, "Invalid client MAC address"));
    }
    find_client_by_filter(state, "macAddress", mac).await
}

/// Fetches the first UniFi client matching one filter field and value.
///
/// # Errors
/// Returns HTTP 404 when no client matches, or HTTP 502 if the upstream request
/// or response decoding fails.
async fn find_client_by_filter(
    state: &AppState,
    field: &str,
    value: &str,
) -> Result<UnifiClient, AppError> {
    let unifi_client_req = state
        .client
        .get(integration_clients_url(&state.config))
        .header("X-API-Key", &state.config.unifi_api_key)
        .query(&[("filter", format!("{field}.eq('{value}')"))])
        .send()
        .await
        .map_err(upstream_error)?
        .error_for_status()
        .map_err(upstream_error)?
        .json::<UnifiClientResponse>()
        .await
        .map_err(upstream_error)?;

    unifi_client_req
        .data
        .into_iter()
        .next()
        .ok_or((StatusCode::NOT_FOUND, "UniFi client not found"))
}

/// Logs a Reqwest error without its URL and returns a generic HTTP 502 response.
fn upstream_error(error: reqwest::Error) -> AppError {
    eprintln!("Upstream request failed: {}", error);
    (StatusCode::BAD_GATEWAY, "Upstream request failed")
}
