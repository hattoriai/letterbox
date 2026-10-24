defmodule Letterbox.PlugTest do
  use LetterboxTest.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  @moduletag :db

  defmodule Router do
    use Phoenix.Router

    # A path of the app's choosing: the reader finds the plug by itself.
    post "/mail/from-resend", Letterbox.Plug, ingress: :resend
  end

  defp webhook(name, body, headers) do
    conn(:post, "/inbound/webhooks/#{name}", body)
    |> Map.put(:path_params, %{"ingress" => name})
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    end)
    |> Letterbox.Plug.call(Letterbox.Plug.init([]))
  end

  describe "the relay" do
    test "takes a raw email with its token, and its envelope" do
      raw =
        Letterbox.Email.build(
          from: "a@example.com",
          to: "list@else.org",
          subject: "Relayed",
          text: "x"
        )

      conn =
        webhook("relay", raw, [
          {"content-type", "message/rfc822"},
          {"authorization", "Bearer relay-test-token"},
          {"x-letterbox-recipients", "support@example.com"},
          {"x-letterbox-id", "relay-1"}
        ])

      assert conn.status == 204

      assert [
               %{
                 status: "delivered",
                 ingress: "relay",
                 external_id: "relay-1",
                 subject: "Relayed"
               }
             ] = Letterbox.list()
    end

    test "takes the token as basic auth's password" do
      raw = Letterbox.Email.build(to: "support@example.com", text: "x")
      auth = "Basic " <> Base.encode64("letterbox:relay-test-token")

      assert webhook("relay", raw, [{"authorization", auth}]).status == 204
    end

    test "refuses a wrong token, and keeps nothing" do
      raw = Letterbox.Email.build(to: "support@example.com", text: "x")

      assert webhook("relay", raw, [{"authorization", "Bearer wrong"}]).status == 401
      assert webhook("relay", raw, []).status == 401
      assert Letterbox.list() == []
    end
  end

  test "a route at any path that names its ingress" do
    raw = Letterbox.Email.build(to: "support@example.com", text: "x")

    conn =
      conn(:post, "/mail/hooks/postfix", raw)
      |> put_req_header("authorization", "Bearer relay-test-token")
      |> Letterbox.Plug.call(Letterbox.Plug.init(ingress: :relay))

    assert conn.status == 204
    assert [%{ingress: "relay", status: "delivered"}] = Letterbox.list()
  end

  test "a route with no ingress, by option or path, is a 404" do
    conn = conn(:post, "/inbound/webhooks", "x") |> Letterbox.Plug.call(Letterbox.Plug.init([]))
    assert conn.status == 404
  end

  test "an ingress not in the config is a 404" do
    assert webhook("mailgun", "{}", []).status == 404
  end

  describe "Resend" do
    @secret "letterbox-test-signing-secret"

    defp signed(body, opts \\ []) do
      id = "msg_1"
      timestamp = Integer.to_string(Keyword.get(opts, :at, System.system_time(:second)))

      signature =
        :crypto.mac(:hmac, :sha256, @secret, "#{id}.#{timestamp}.#{body}") |> Base.encode64()

      [
        {"content-type", "application/json"},
        {"svix-id", id},
        {"svix-timestamp", timestamp},
        {"svix-signature", "v1,#{signature}"}
      ]
    end

    setup do
      raw =
        Letterbox.Email.build(
          from: "ana@example.com",
          to: "someone@else.org",
          subject: "From Resend",
          text: "x"
        )

      Req.Test.stub(LetterboxTest.Resend, fn conn ->
        case conn.request_path do
          "/emails/receiving/" <> id ->
            assert get_req_header(conn, "authorization") == ["Bearer re_test"]

            Req.Test.json(conn, %{
              "id" => id,
              "received_for" => ["support@example.com"],
              "raw" => %{
                "download_url" => "https://storage.example/raw/#{id}",
                "expires_at" => "later"
              }
            })

          "/raw/" <> _id ->
            send_resp(conn, 200, raw)
        end
      end)

      :ok
    end

    test "an email received is fetched, kept and given to its mailbox, by its envelope" do
      body =
        JSON.encode!(%{
          "type" => "email.received",
          "data" => %{
            "email_id" => "em_1",
            "to" => ["someone@else.org"],
            "received_for" => ["support@example.com"]
          }
        })

      assert webhook("resend", body, signed(body)).status == 204

      assert [inbound] = Letterbox.list()

      assert %{
               status: "delivered",
               ingress: "resend",
               external_id: "em_1",
               subject: "From Resend"
             } = inbound

      assert inbound.recipients == ["support@example.com"]
      assert_received {:processed, LetterboxTest.Recorder, _message}
    end

    test "through the endpoint's parsers, which read JSON first, with the shared reader" do
      body =
        JSON.encode!(%{
          "type" => "email.received",
          "data" => %{"email_id" => "em_parsed", "received_for" => ["support@example.com"]}
        })

      parsers =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: JSON,
          body_reader: {PhoenixMountable.RawBody, :read_body, [Router]}
        )

      conn =
        Enum.reduce(signed(body), conn(:post, "/mail/from-resend", body), fn {k, v}, conn ->
          put_req_header(conn, k, v)
        end)
        |> Plug.Parsers.call(parsers)

      assert conn.body_params["type"] == "email.received"
      assert Router.call(conn, Router.init([])).status == 204
      assert [%{external_id: "em_parsed", status: "delivered"}] = Letterbox.list()
    end

    test "without the shared reader, the parsers' body cannot be checked: a 500 that says why" do
      body = JSON.encode!(%{"type" => "email.received", "data" => %{"email_id" => "em_lost"}})
      parsers = Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: JSON)

      conn =
        Enum.reduce(signed(body), conn(:post, "/mail/from-resend", body), fn {k, v}, conn ->
          put_req_header(conn, k, v)
        end)
        |> Plug.Parsers.call(parsers)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Router.call(conn, Router.init([])).status == 500
        end)

      assert log =~ "PhoenixMountable.RawBody"
    end

    test "the same event twice is one message" do
      body = JSON.encode!(%{"type" => "email.received", "data" => %{"email_id" => "em_2"}})

      assert webhook("resend", body, signed(body)).status == 204
      assert webhook("resend", body, signed(body)).status == 204
      assert length(Letterbox.list()) == 1
    end

    test "events of other kinds are answered, and nothing is kept" do
      body = JSON.encode!(%{"type" => "email.delivered", "data" => %{"email_id" => "em_3"}})

      assert webhook("resend", body, signed(body)).status == 204
      assert Letterbox.list() == []
    end

    test "a wrong or old signature is refused" do
      body = JSON.encode!(%{"type" => "email.received", "data" => %{"email_id" => "em_4"}})

      assert webhook("resend", body, signed(body <> " ")).status == 401

      assert webhook("resend", body, signed(body, at: System.system_time(:second) - 600)).status ==
               401
    end

    test "while Resend does not give the email, it waits, then fails" do
      Req.Test.stub(LetterboxTest.Resend, &send_resp(&1, 503, "unavailable"))
      body = JSON.encode!(%{"type" => "email.received", "data" => %{"email_id" => "em_5"}})

      assert webhook("resend", body, signed(body)).status == 204
      assert [%{status: "failed", attempts: 3, error: "{:resend, 503}"}] = Letterbox.list()
    end
  end
end
