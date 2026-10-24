defmodule LetterboxTest.Mailboxes do
  @moduledoc "The routes of the tests."
  use Letterbox.Routing

  route("support@example.com", to: LetterboxTest.Recorder)
  route(~r/\Areply\+/, to: LetterboxTest.Recorder)
  route("photos@", to: LetterboxTest.Photos)
  route("bounce@", to: LetterboxTest.Bouncer)
  route("flaky@", to: LetterboxTest.Flaky)
  route("crash@", to: LetterboxTest.Crasher)
  route("@sites.example.com", to: LetterboxTest.Recorder)
end

defmodule LetterboxTest.Recorder do
  @moduledoc "Sends each message to the test's process."
  use Letterbox.Mailbox

  @impl true
  def process(message) do
    send(owner(), {:processed, __MODULE__, message})
    :ok
  end

  @doc false
  def owner, do: hd(Process.get(:"$callers", [self()]) ++ [self()])
end

defmodule LetterboxTest.Photos do
  @moduledoc "Keeps the images, as an app's media library would."
  use Letterbox.Mailbox

  @impl true
  def process(message) do
    stored =
      for attachment <- message.attachments,
          String.starts_with?(attachment.content_type, "image/") do
        Letterbox.Attachment.store(attachment, owner: "sites/1")
      end

    send(LetterboxTest.Recorder.owner(), {:stored, stored})
    :ok
  end
end

defmodule LetterboxTest.Bouncer do
  @moduledoc "Refuses every message."
  use Letterbox.Mailbox

  @impl true
  def process(_message), do: {:bounce, :unknown_sender}
end

defmodule LetterboxTest.Flaky do
  @moduledoc "Fails until its second attempt."
  use Letterbox.Mailbox

  @impl true
  def process(message) do
    count = Process.get({__MODULE__, message.id}, 0) + 1
    Process.put({__MODULE__, message.id}, count)
    if count < 2, do: {:error, :not_yet}, else: :ok
  end
end

defmodule LetterboxTest.Crasher do
  @moduledoc "Raises."
  use Letterbox.Mailbox

  @impl true
  def process(_message), do: raise("the mailbox crashed")
end

defmodule LetterboxTest.Hold do
  @moduledoc "A runner that keeps its jobs and runs none: messages wait, as after a restart."
  @behaviour Letterbox.Runner

  @impl true
  def enqueue(_job, _opts), do: :ok
end
