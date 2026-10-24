defmodule Letterbox.Attachment do
  @moduledoc """
  A file that came with a message: a photograph, a PDF, an invitation,
  a forwarded email.

  Nothing of it is decoded until the app asks: `read/1` gives its bytes,
  for a small file; `save/3` writes it to a file as it is decoded, with
  its size and checksum; `store/2` keeps it in the app's store with
  Storehouse, checked by its bytes, under the app's limits:

      for attachment <- message.attachments, String.starts_with?(attachment.content_type, "image/") do
        Letterbox.Attachment.store(attachment,
          accept: Storehouse.Check.images(),
          max_bytes: 50_000_000,
          owner: "sites/\#{site.id}",
          room: Media.room(site),
          existing: &Media.by_checksum(site, &1)
        )
      end

  `:inline?` is true for a file that the message's HTML shows in its text
  (a `cid:` image): a logo in a signature, but also, from a phone, the
  photographs someone put in the body. Whether to keep those is the app's
  choice.
  """

  alias Letterbox.MIME

  defstruct [:name, :content_type, :content_id, :encoded_bytes, :part, inline?: false]

  @typedoc """
  An attachment:

    * `:name` - its file name, as the sender's mail client gave it, decoded;
      nil when it has none.
    * `:content_type` - the type the email claims, in lowercase. Only its
      bytes say what it is (`store/2` checks them).
    * `:content_id` - the `Content-ID` the HTML's `cid:` points to, or nil.
    * `:inline?` - whether the HTML shows it in the text.
    * `:encoded_bytes` - the size of its body in the email, before it is
      decoded: about a third more than the file, in Base64.
    * `:part` - its `Letterbox.MIME` part.
  """
  @type t :: %__MODULE__{
          name: String.t() | nil,
          content_type: String.t(),
          content_id: String.t() | nil,
          inline?: boolean(),
          encoded_bytes: non_neg_integer(),
          part: MIME.t()
        }

  @doc false
  @spec new(MIME.t(), boolean()) :: t()
  def new(%MIME{} = part, inline?) do
    %__MODULE__{
      name: part.disposition_params["filename"] || part.params["name"],
      content_type: part.type,
      content_id: part.content_id,
      inline?: inline?,
      encoded_bytes: byte_size(part.body),
      part: part
    }
  end

  @doc "Its bytes, decoded, in memory: for a small file."
  @spec read(t()) :: binary()
  def read(%__MODULE__{part: part}), do: MIME.decode(part)

  @doc "Its bytes, decoded, as a stream of chunks (`Letterbox.MIME.stream/2`)."
  @spec stream(t(), keyword()) :: Enumerable.t()
  def stream(%__MODULE__{part: part}, opts \\ []), do: MIME.stream(part, opts)

  @doc """
  Writes it to `path` as it is decoded, a chunk at a time. Gives `{:ok,
  %{bytes: …, checksum: …}}`, its size and its SHA-256 (in Base64, as
  Storehouse gives checksums), or `{:error, :too_large}` past
  `:max_bytes`, with nothing left at `path`.
  """
  @spec save(t(), Path.t(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), checksum: String.t()}}
          | {:error, :too_large | File.posix()}
  def save(%__MODULE__{} = attachment, path, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, :infinity)

    with {:ok, file} <- File.open(path, [:write, :binary, :raw]) do
      result =
        try do
          attachment
          |> stream()
          |> Enum.reduce_while({:ok, 0, :crypto.hash_init(:sha256)}, fn chunk,
                                                                        {:ok, bytes, hash} ->
            bytes = bytes + byte_size(chunk)

            if max != :infinity and bytes > max do
              {:halt, {:error, :too_large}}
            else
              :ok = IO.binwrite(file, chunk)
              {:cont, {:ok, bytes, :crypto.hash_update(hash, chunk)}}
            end
          end)
        after
          File.close(file)
        end

      case result do
        {:ok, bytes, hash} ->
          {:ok, %{bytes: bytes, checksum: Base.encode64(:crypto.hash_final(hash))}}

        {:error, reason} ->
          File.rm(path)
          {:error, reason}
      end
    end
  end

  @doc """
  Keeps it in the app's store: `Storehouse.store/2` of its bytes, with its
  name and claimed type, and the options given (`:accept`, `:max_bytes`,
  `:owner`, `:room`, `:existing`, `:adapter`, …). It is decoded to a
  temporary file first, which goes once it is stored.

  Gives what `Storehouse.store/2` gives: `{:ok, file}`, `{:existing,
  file}` when the app has the same file already (`:existing`), or `{:error,
  reason}`: `:not_accepted`, `:too_large`, `:storage_full`, …
  """
  @spec store(t(), keyword()) :: {:ok | :existing, Storehouse.File.t()} | {:error, term()}
  def store(%__MODULE__{} = attachment, opts \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "letterbox-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    try do
      with {:ok, _saved} <- save(attachment, path, Keyword.take(opts, [:max_bytes])) do
        Storehouse.store(
          path,
          [
            name: attachment.name || default_name(attachment),
            content_type: attachment.content_type
          ] ++
            opts
        )
      end
    after
      File.rm(path)
    end
  end

  defp default_name(%__MODULE__{content_type: type}) do
    # The mime package's MIME (Plug's), not Letterbox.MIME.
    case Elixir.MIME.extensions(type) do
      [extension | _] -> "attachment." <> extension
      [] -> "attachment"
    end
  end
end
