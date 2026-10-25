# steam-cdn 1.0.0 patches

Upstream source: published `steam-cdn` 1.0.0 crate, copied verbatim from
`artifacts/ios-workshop/crates/steam-cdn-1.0.0` (not a moving git reference).
The published crate archive SHA-256 is
`48a8311e77f9cae1aca69e296450608f9cb389279c183fd833d8a32c6ce71eca`.
Its embedded VCS revision is `5506382590450a77e11c77026aa03cbd7a74cd3d`.
License: Apache-2.0. The source archive includes its `LICENSE`; the separately
provided reference copy was preserved as `LICENSE` here.

Security modifications:

- Configure CDN HTTP client for 15-second connect and 60-second total request
  timeouts; require HTTPS and a DNS-label boundary match beneath Steam-owned
  CDN domains, and re-check response URL after redirects.
- Bound manifest/chunk response-body accumulation to 16 MiB / 8 MiB using
  streamed response chunks, with early Content-Length rejection.
- Bound manifest ZIP member expansion to 64 MiB, individual protobuf frame
  allocation to 64 MiB, mapping count to 100,000, and metadata original size to
  20 GiB. Reject truncated/overlong ZIP output.
- Bound ZIP depot chunk output to 4 MiB; cap VZ/LZMA declared output to 4 MiB
  and dictionary size to 64 MiB; verify declared output length and existing CRC.
- Replace the semaphore-wrapped `FuturesOrdered` queue (which eagerly retained
  one future per manifest chunk) with ordered sequential fetching. Validate
  contiguous offsets, each chunk's declared size, and final file size. Final
  file SHA-1 remains the integration caller's responsibility.

The bounded limits and Steam-host matching have unit-level checks in the crate;
there is intentionally no network test.
