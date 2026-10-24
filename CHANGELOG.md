# Changelog

All notable changes to Letterbox are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Letterbox follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.1.0-rc.0] - 2026-10-24

### Added

- Emails to the app, kept and given to its code: `Letterbox.ingest/2`, a
  row for each message (`Letterbox.Inbound`, `Letterbox.Migrations`) with
  its raw email in Storehouse, routes (`Letterbox.Routing`) and mailboxes
  (`Letterbox.Mailbox`), retried out of the request on Oban or a process
  of Letterbox's (`Letterbox.Runner`), resumed after a restart and
  deleted when old (`Letterbox.Sweeper`).
- A MIME parser of Letterbox's own (`Letterbox.MIME`): it copies nothing,
  and decodes an attachment in chunks; every charset of the WHATWG
  Encoding Standard (`Letterbox.Charset`); encoded words and RFC 2231
  parameters (`Letterbox.MIME.Header`); addresses, groups and
  sub-addresses (`Letterbox.Address`).
- `Letterbox.Message`: who sent it, and who a trusted server verified;
  where it was delivered and which recipient its route matched; its text
  (or text from its HTML), HTML, attachments (`Letterbox.Attachment`,
  stored with Storehouse) and links to files sent another way; its
  threads' ids.
- Ingresses (`Letterbox.Ingress`): Resend's webhook (`Letterbox.Ingress.Resend`)
  and a relay of raw emails (`Letterbox.Ingress.Relay`), at a route of the
  app's own (`Letterbox.Plug`), with the body as it was sent
  (`PhoenixMountable.RawBody`).
- `mix letterbox.install`, on Igniter.
- The development page (`Letterbox.Dev.Router`).
- `Letterbox.Test`, for an app's tests of its mailboxes and routes.
- Telemetry of each message kept and processed.
