use reqwest::{Client, Response};
use std::{sync::Arc, time::Duration};
use super::depot_chunk;
use steam_vent::{
    proto::steammessages_clientserver_appinfo::{
        cmsg_client_picsproduct_info_request::AppInfo, CMsgClientPICSAccessTokenRequest,
        CMsgClientPICSAccessTokenResponse, CMsgClientPICSProductInfoRequest,
        CMsgClientPICSProductInfoResponse,
    },
    Connection, ConnectionTrait,
};

use crate::{web_api::content_service::CDNServer, Error};

const HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const HTTP_TIMEOUT: Duration = Duration::from_secs(60);
pub(crate) const MANIFEST_RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
const CHUNK_RESPONSE_LIMIT: usize = 8 * 1024 * 1024;

pub(crate) async fn read_limited(mut response: Response, limit: usize) -> Result<Vec<u8>, Error> {
    if response.content_length().is_some_and(|len| len > limit as u64) {
        return Err(Error::Unexpected("response exceeds configured size limit".into()));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if chunk.len() > limit.saturating_sub(body.len()) {
            return Err(Error::Unexpected("response exceeds configured size limit".into()));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

pub(crate) async fn read_manifest_response(response: Response) -> Result<Vec<u8>, Error> {
    read_limited(response, MANIFEST_RESPONSE_LIMIT).await
}

#[cfg(test)]
mod security_tests {
    use super::*;

    #[test]
    fn allows_only_exact_steam_domain_boundaries() {
        assert!(allowed_cdn_host("cache.steamcontent.com"));
        assert!(allowed_cdn_host("STEAMCONTENT.COM"));
        assert!(!allowed_cdn_host("steamcontent.com.attacker.test"));
        assert!(!allowed_cdn_host("notsteamcontent.com"));
        assert!(!allowed_cdn_host("localhost"));
        assert!(!allowed_cdn_host("127.0.0.1"));
    }

    #[test]
    fn response_limit_rejects_excess_without_network() {
        assert_eq!(MANIFEST_RESPONSE_LIMIT, 16 * 1024 * 1024);
        assert_eq!(CHUNK_RESPONSE_LIMIT, 8 * 1024 * 1024);
    }
}

fn allowed_cdn_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    ["steamcontent.com", "steampowered.com", "steamstatic.com", "steamserver.net"]
        .iter()
        .any(|suffix| host == *suffix || host.strip_suffix(suffix).is_some_and(|prefix| prefix.ends_with('.')))
}

#[derive(Debug)]
pub(crate) struct InnerClient {
    pub connection: Arc<Connection>,
    web_client: Client,
    pub servers: Vec<CDNServer>,
}

impl InnerClient {
    pub fn new(connection: Arc<Connection>) -> Self {
        Self {
            connection,
            web_client: Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(HTTP_CONNECT_TIMEOUT)
                .timeout(HTTP_TIMEOUT)
                .build()
                .expect("valid CDN HTTP client configuration"),
            servers: Vec::new(),
        }
    }

    pub fn cell_id(&self) -> u32 {
        self.connection.cell_id()
    }

    fn get_server(&self) -> Result<&CDNServer, Error> {
        match self
            .servers
            .iter()
            .find(|&server| server.https && allowed_cdn_host(&server.host) && server.cell_id == self.connection.cell_id())
        {
            Some(server) => Ok(server),
            None => self
                .servers
                .iter()
                .find(|server| server.https && allowed_cdn_host(&server.host) && (server.r#type == "SteamCache" || server.r#type == "CDN"))
                .ok_or(Error::Network("no available cdn servers".to_string())),
        }
    }

    pub async fn get_product_info(
        &self,
        app_ids: Vec<u32>,
    ) -> Result<CMsgClientPICSProductInfoResponse, Error> {
        let tokens: CMsgClientPICSAccessTokenResponse = self
            .connection
            .job(CMsgClientPICSAccessTokenRequest {
                appids: app_ids,
                ..Default::default()
            })
            .await?;

        let product_info: CMsgClientPICSProductInfoResponse = self
            .connection
            .job(CMsgClientPICSProductInfoRequest {
                apps: tokens
                    .app_access_tokens
                    .into_iter()
                    .map(|app_token| AppInfo {
                        appid: app_token.appid,
                        access_token: app_token.access_token,
                        ..Default::default()
                    })
                    .collect::<Vec<AppInfo>>(),
                meta_data_only: Some(false),
                ..Default::default()
            })
            .await?;
        Ok(product_info)
    }

    pub async fn remote_cmd<C: AsRef<str>, A: AsRef<str>>(
        &self,
        command: C,
        args: A,
        manifest_request_code: Option<u64>,
    ) -> Result<Response, Error> {
        let server = self.get_server()?;
        if !server.https || !allowed_cdn_host(&server.host) {
            return Err(Error::Unexpected("CDN server must use HTTPS and an allowed Steam host".into()));
        }
        let mut url = format!(
            "https://{}:{}/{}/{}",
            server.host,
            server.port,
            command.as_ref(),
            args.as_ref()
        );
        if let Some(manifest_request_code) = manifest_request_code {
            url.push('/');
            url.push_str(manifest_request_code.to_string().as_str());
        }
        let response = self.web_client.get(url).send().await?;
        if response.url().scheme() != "https" || !allowed_cdn_host(response.url().host_str().unwrap_or_default()) {
            return Err(Error::Unexpected("CDN redirected outside allowed HTTPS hosts".into()));
        }
        Ok(response)
    }

    pub async fn get_chunk(
        &self,
        depot_id: u32,
        depot_key: [u8; 32],
        chunk_id: String,
    ) -> Result<Vec<u8>, Error> {
        let response = self
            .remote_cmd("depot", format!("{depot_id}/chunk/{chunk_id}"), None)
            .await?;
        if !response.status().is_success() {
            return Err(Error::HttpStatus(response.status()));
        }

        let mut bytes = read_limited(response, CHUNK_RESPONSE_LIMIT).await?;
        depot_chunk::decrypt_and_decompress(&mut bytes[..], depot_key).await
    }
}
