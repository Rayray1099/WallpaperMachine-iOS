use reqwest::Client;

use crate::Error;

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ContentServer {
    pub r#type: String,
    pub source_id: u64,
    pub cell_id: Option<u32>,
    pub load: u32,
    #[serde(deserialize_with = "nonnegative_finite_load")]
    pub weighted_load: f64,
    pub num_entries_in_client_list: u32,
    pub host: String,
    pub vhost: String,
    pub https_support: String,
    pub priority_class: u32,
}

#[derive(Debug, Deserialize)]
struct ContentServerDirectoryInner {
    pub servers: Vec<ContentServer>,
}

#[derive(Debug, Deserialize)]
struct ContentServerDirectory {
    pub response: ContentServerDirectoryInner,
}

#[allow(dead_code)]
#[derive(Debug)]
pub struct CDNServer {
    pub r#type: String,
    pub https: bool,
    pub host: String,
    pub vhost: String,
    pub port: u16,
    pub cell_id: u32,
    pub load: u32,
    pub weighted_load: f64,
}

fn nonnegative_finite_load<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<f64, D::Error> {
    let value = <f64 as serde::Deserialize>::deserialize(deserializer)?;
    if value.is_finite() && value >= 0.0 {
        Ok(value)
    } else {
        Err(serde::de::Error::custom("invalid CDN weighted load"))
    }
}

fn supports_https(value: &str) -> bool {
    matches!(value, "mandatory" | "optional")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_server_directory_accepts_fractional_weighted_load() {
        // Valve's public directory returns fractional scores, including 171.25.
        let json = r#"{"response":{"servers":[{"type":"SteamCache","source_id":290,"cell_id":33,"load":47,"weighted_load":171.25,"num_entries_in_client_list":1,"host":"cache6-hkg1.steamcontent.com","vhost":"cache6-hkg1.steamcontent.com","https_support":"mandatory","priority_class":9}]}}"#;
        let parsed = serde_json::from_str::<ContentServerDirectory>(json);
        assert!(parsed.is_ok(), "fractional directory score must deserialize: {parsed:?}");
        assert_eq!(parsed.unwrap().response.servers[0].weighted_load, 171.25);
    }

    #[derive(Debug, Deserialize)]
    struct Load {
        #[serde(deserialize_with = "nonnegative_finite_load")]
        value: f64,
    }

    #[test]
    fn weighted_load_orders_integer_and_fractional_scores() {
        let mut loads: Vec<f64> = ["0", "171.25", "167.5", "171", "1e2"].iter()
            .map(|score| serde_json::from_str::<Load>(&format!("{{\"value\":{score}}}")).unwrap().value)
            .collect();
        loads.sort_by(f64::total_cmp);
        assert_eq!(loads, [0.0, 100.0, 167.5, 171.0, 171.25]);
    }

    #[test]
    fn weighted_load_rejects_malformed_or_nonfinite_values() {
        for score in ["-1", "-0.25", "1e999", "NaN", "Infinity", "null", "true", "\"171.25\"", "{}", "[]"] {
            assert!(serde_json::from_str::<Load>(&format!("{{\"value\":{score}}}")).is_err(), "accepted {score}");
        }
        // A non-JSON deserializer can supply IEEE infinities/NaN directly.
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let deserializer = serde::de::value::F64Deserializer::<serde::de::value::Error>::new(value);
            assert!(nonnegative_finite_load(deserializer).is_err());
        }
    }

    #[test]
    fn https_support_is_explicit_and_fail_closed() {
        for value in ["mandatory", "optional"] {
            assert!(supports_https(value));
        }
        for value in ["none", "unavailable", "", "unknown", "true", "MANDATORY"] {
            assert!(!supports_https(value));
        }
    }
}

pub async fn get_servers_for_steam_pipe(cell_id: u32) -> Result<Vec<CDNServer>, Error> {
    Ok(
        Client::builder()
            .connect_timeout(std::time::Duration::from_secs(15))
            .timeout(std::time::Duration::from_secs(60))
            .redirect(reqwest::redirect::Policy::none())
            .build().map_err(|error| Error::Network(error.to_string()))?
            .get("https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/")
            .query(&[("cell_id", cell_id)])
            .send().await?
            .json::<ContentServerDirectory>().await?
            .response
            .servers
            .into_iter()
            .map(|server| {
                // Fail closed for unavailable/none/unknown values. CDN requests
                // still use HTTPS exclusively; there is no HTTP fallback.
                let https = supports_https(&server.https_support);
                CDNServer {
                    r#type: server.r#type,
                    https,
                    host: server.host,
                    vhost: server.vhost,
                    port: 443,
                    cell_id: server.cell_id.unwrap_or(0),
                    load: server.load,
                    weighted_load: server.weighted_load,
                }
            })
            .collect::<Vec<CDNServer>>()
    )
}
