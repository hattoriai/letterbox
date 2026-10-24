import Config

if config_env() == :test do
  config :logger, level: :warning

  config :storehouse, adapter: Storehouse.Memory

  config :letterbox,
    repo: LetterboxTest.Repo,
    routing: LetterboxTest.Mailboxes,
    runner: :inline,
    max_attempts: 3,
    ingresses: [
      resend: [
        secret: "whsec_" <> Base.encode64("letterbox-test-signing-secret"),
        api_key: "re_test",
        req_options: [plug: {Req.Test, LetterboxTest.Resend}]
      ],
      relay: [token: "relay-test-token"]
    ]
end
