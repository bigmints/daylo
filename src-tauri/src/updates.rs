//! Whether there is a newer Daylo, for the platforms the updater plugin does not reach.
//!
//! On the desktop this whole question belongs to `tauri-plugin-updater`, which reads a
//! manifest, checks its signature and installs what it finds. None of that exists on
//! Android: the plugin is not built for it, and the page cannot ask either, because the
//! app's CSP is `default-src 'none'`. So the asking is done here and the answer is one
//! string: the version the manifest names.
//!
//! What this file does not do is decide anything. It does not compare versions, it does
//! not know whether this copy came from Play, and it does not open anything. Those are
//! decisions with rules attached and they live on the other side, where they can be read
//! next to the rest of the rules.
//!
//! The address is **read from the app's own configuration** rather than written here, and
//! that is not tidiness. `scripts/check-no-analytics.sh` promises that one file in the
//! native half may name a host and names which; a second address here would make that
//! sentence false while the script stayed green, because what it greps for in other files
//! is analytics services. Reading `plugins.updater.endpoints` keeps one address in the
//! repository, the one the desktop already reads, in the file where it is declared.

// Only Android calls these, and the module still compiles everywhere so that `cargo test`
// on a laptop reads them. For the library target on any other platform that makes them
// dead code, which `-D warnings` would stop the build over. Allowed here and nowhere else,
// and narrowed to the platforms that genuinely do not call it, so the day something on the
// desktop stops being used the warning still arrives.
#![cfg_attr(not(target_os = "android"), allow(dead_code))]

use serde_json::Value;

/// How much of a manifest is worth reading. The real one is about 3 kB.
pub const MANIFEST_LIMIT: usize = 64 * 1024;

/// The address the updater is configured to read, or why it could not be had.
///
/// Every failure is an error rather than an absence, and that distinction is the point:
/// "there is no newer version" and "I could not find out" are different answers, and a
/// screen that shows the first when it means the second is telling somebody they are up
/// to date on no evidence.
pub fn endpoint(updater: Option<&Value>) -> Result<String, String> {
    let configured = updater
        .and_then(|block| block.get("endpoints"))
        .and_then(|endpoints| endpoints.as_array())
        .ok_or("the configuration names no updater endpoints")?;

    let first = configured
        .first()
        .and_then(|value| value.as_str())
        .ok_or("the updater endpoint list is empty")?;

    // The updater plugin expands `{{target}}` and friends before it asks. Nothing here
    // does, so an endpoint that needs expanding is refused rather than fetched with the
    // braces still in it: a 404 would arrive as "no newer version", which is a wrong
    // answer rather than a failure. Daylo's endpoint has no placeholders, and the test
    // below reads the real file to keep that true.
    if first.contains("{{") {
        return Err("the updater endpoint needs values this does not know how to fill".into());
    }

    Ok(first.to_string())
}

/// The version a manifest names, or why it could not be had.
pub fn version_in(manifest: &str) -> Result<String, String> {
    let parsed: Value =
        serde_json::from_str(manifest).map_err(|_| "the manifest is not readable".to_string())?;

    match parsed.get("version").and_then(|value| value.as_str()) {
        Some(version) if !version.trim().is_empty() => Ok(version.to_string()),
        _ => Err("the manifest names no version".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::{endpoint, version_in};
    use serde_json::json;

    #[test]
    fn reads_the_address_the_updater_is_given() {
        let updater = json!({ "endpoints": ["https://example.test/latest.json"] });
        assert_eq!(
            endpoint(Some(&updater)).unwrap(),
            "https://example.test/latest.json"
        );
    }

    /// Four kinds of nothing, and all four are a failure rather than an answer. The one
    /// that matters most is the first: the updater plugin is not registered on Android,
    /// and a configuration block that arrived empty there would otherwise be read as
    /// "nothing to update".
    #[test]
    fn an_address_it_cannot_have_is_a_failure_and_not_an_answer() {
        assert!(endpoint(None).is_err());
        assert!(endpoint(Some(&json!({}))).is_err());
        assert!(endpoint(Some(&json!({ "endpoints": [] }))).is_err());
        assert!(endpoint(Some(&json!({ "endpoints": [7] }))).is_err());
    }

    /// The plugin expands these before asking and this does not. Fetching one with the
    /// braces still in it would 404, and a 404 would read as "no newer version".
    #[test]
    fn refuses_an_address_with_holes_in_it() {
        let updater = json!({ "endpoints": ["https://example.test/{{target}}/latest.json"] });
        assert!(endpoint(Some(&updater)).is_err());
    }

    /// The real file, so that adding a placeholder to the endpoint fails here rather than
    /// on somebody's phone, where the failure is silence.
    #[test]
    fn the_configured_address_is_one_this_can_actually_fetch() {
        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let updater = config
            .get("plugins")
            .and_then(|plugins| plugins.get("updater"));

        let address = endpoint(updater).expect("tauri.conf.json must name a fetchable endpoint");
        assert!(address.starts_with("https://"));
    }

    #[test]
    fn reads_the_version_a_manifest_names() {
        assert_eq!(version_in(r#"{"version":"1.5.0"}"#).unwrap(), "1.5.0");
    }

    #[test]
    fn a_manifest_it_cannot_read_is_a_failure_and_not_an_answer() {
        assert!(version_in("").is_err());
        assert!(version_in("<html>404</html>").is_err());
        assert!(version_in(r#"{"notes":"hello"}"#).is_err());
        assert!(version_in(r#"{"version":"  "}"#).is_err());
    }
}
