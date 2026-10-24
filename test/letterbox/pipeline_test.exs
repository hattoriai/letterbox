defmodule Letterbox.PipelineTest do
  use LetterboxTest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Letterbox.Inbound

  @moduletag :db

  test "a message goes to its mailbox, with the recipient its route matched" do
    inbound =
      deliver(
        from: "Ana <ana@example.com>",
        to: "support+urgent@example.com",
        subject: "Help",
        text: "Hello"
      )

    assert %Inbound{status: "delivered", mailbox: "LetterboxTest.Recorder", attempts: 1} = inbound
    assert %{from: "ana@example.com", subject: "Help", ingress: "test"} = inbound
    assert inbound.raw_key =~ ~r"\Aletterbox/\d{4}/\d{2}/#{inbound.id}\.eml\z"

    assert_received {:processed, LetterboxTest.Recorder, message}
    assert message.id == inbound.id
    assert message.recipient.address == "support+urgent@example.com"
    assert message.text == "Hello"
  end

  test "the envelope's recipients route a message its To does not name (Bcc)" do
    inbound =
      deliver([from: "a@example.com", to: "someone@else.org", text: "x"],
        recipients: ["support@example.com"]
      )

    assert inbound.status == "delivered"
    assert inbound.recipients == ["support@example.com"]
  end

  test "a mailbox keeps the photographs with Storehouse" do
    photo = :crypto.strong_rand_bytes(40_000)
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0>> <> photo

    deliver(
      from: "ana@example.com",
      to: "photos@in.example.com",
      text: "From the beach",
      attachments: [
        %{name: "praia.jpg", content_type: "image/jpeg", data: jpeg},
        %{name: "notes.txt", content_type: "text/plain", data: "not a photo"}
      ]
    )

    assert_received {:stored, [{:ok, file}]}
    assert file.name == "praia.jpg"
    assert file.key =~ ~r{\Asites/1/}
    assert Storehouse.read(file.key) == {:ok, jpeg}
  end

  test "a bounce is for good" do
    inbound = deliver(from: "a@example.com", to: "bounce@example.com", text: "x")
    assert %Inbound{status: "bounced", error: "unknown_sender", attempts: 1} = inbound
  end

  test "a message no route takes is unrouted" do
    assert %Inbound{status: "unrouted", mailbox: nil} =
             deliver(to: "nobody@example.com", text: "x")
  end

  test "an error is tried again" do
    assert %Inbound{status: "delivered", attempts: 2} =
             deliver(to: "flaky@example.com", text: "x")
  end

  test "an exception is tried again, then the message has failed, with why" do
    log =
      capture_log(fn -> send(self(), {:inbound, deliver(to: "crash@example.com", text: "x")}) end)

    assert_received {:inbound, inbound}

    assert %Inbound{status: "failed", attempts: 3, mailbox: "LetterboxTest.Crasher"} = inbound
    assert inbound.error =~ "the mailbox crashed"
    assert log =~ "LetterboxTest.Crasher raised"
  end

  test "the same provider's id twice is one message" do
    first = deliver([to: "support@example.com", text: "x"], external_id: "abc")
    second = deliver([to: "support@example.com", text: "x"], external_id: "abc")

    assert first.id == second.id
    assert Repo.aggregate(Inbound, :count) == 1
  end

  test "an email past :max_bytes is bounced, and not kept" do
    Application.put_env(:letterbox, :max_bytes, 1_000)
    on_exit(fn -> Application.delete_env(:letterbox, :max_bytes) end)

    {:ok, inbound} =
      Letterbox.ingest(
        Letterbox.Email.build(to: "support@example.com", text: String.duplicate("x", 2_000))
      )

    assert %Inbound{status: "bounced", error: "too_large", raw_key: nil} = inbound
  end

  test "a message is read again from its raw email" do
    inbound =
      deliver(from: "a@example.com", to: "support@example.com", subject: "Again", text: "x")

    assert {:ok, %Letterbox.Message{subject: "Again", id: id}} = Letterbox.message(inbound.id)
    assert id == inbound.id
    assert {:ok, raw} = Letterbox.raw(inbound)
    assert raw =~ "Subject: Again"
  end

  test "a bounced message is given to its mailbox again on retry, from its first attempt" do
    inbound = deliver(to: "bounce@example.com", text: "x")
    {:ok, retried} = Letterbox.retry(inbound, runner: :inline)

    assert %Inbound{status: "bounced", attempts: 1} = retried
  end

  test "the messages that were waiting go to the runner again" do
    {:ok, inbound} =
      Letterbox.ingest(Letterbox.Email.build(to: "support@example.com", text: "x"),
        runner: LetterboxTest.Hold
      )

    assert Letterbox.get(inbound.id).status == "received"

    assert Letterbox.resume(runner: :inline) == 1
    assert Letterbox.get(inbound.id).status == "delivered"
  end

  test "messages done with for longer than the days given are deleted, with their raw email" do
    old = deliver(to: "support@example.com", text: "old")
    new = deliver(to: "support@example.com", text: "new")

    old
    |> Ecto.Changeset.change(
      processed_at: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    )
    |> Repo.update!()

    assert Letterbox.incinerate(30) == 1
    assert Letterbox.get(old.id) == nil
    assert {:error, _gone} = Storehouse.read(old.raw_key)
    assert Letterbox.get(new.id)
  end

  test "lists, newest first, by status" do
    deliver(to: "support@example.com", text: "1")
    deliver(to: "bounce@example.com", text: "2")

    assert [%Inbound{status: "bounced"}] = Letterbox.list(status: "bounced")
    assert length(Letterbox.list()) == 2
  end

  test "telemetry of each message kept and processed" do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      inspect(ref),
      [[:letterbox, :ingest, :stop], [:letterbox, :process, :stop]],
      fn event, _measurements, meta, _config -> send(pid, {ref, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    deliver(to: "support@example.com", text: "x")

    assert_received {^ref, [:letterbox, :ingest, :stop], %{result: "received", ingress: "test"}}

    assert_received {^ref, [:letterbox, :process, :stop],
                     %{result: :delivered, mailbox: LetterboxTest.Recorder}}
  end
end
