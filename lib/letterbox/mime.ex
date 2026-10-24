defmodule Letterbox.MIME do
  @moduledoc """
  An email's structure (MIME, RFC 2045 to 2049): its parts, their headers
  and their bodies, still encoded.

      part = Letterbox.MIME.parse(raw)
      part.type          #=> "multipart/mixed"
      Enum.map(part.parts, & &1.type)
      #=> ["multipart/alternative", "image/jpeg"]

  Parsing copies nothing: each part's `:body` is a sub-binary of `raw`,
  the bytes where they are. A body is decoded only when it is asked for:
  a text with `text/1`, any body with `decode/1`, and an attachment as a
  stream of chunks with `stream/2`, so a photograph of 8 MB goes to a file
  without its decoded bytes ever all in memory.

  The parser takes what mail clients send: `LF` as well as `CRLF`, a
  multipart with no closing boundary, a part with no headers, a boundary
  in quotes or not. It stops where an email would make it work without
  end: past `:max_depth` levels of parts in parts (20) or `:max_parts`
  parts (1,000), the rest of a multipart is one part of its type, not
  split.
  """

  alias Letterbox.Charset
  alias Letterbox.MIME.Header

  defstruct type: "text/plain",
            params: %{},
            disposition: nil,
            disposition_params: %{},
            encoding: "7bit",
            content_id: nil,
            headers: [],
            body: "",
            parts: [],
            path: []

  @typedoc """
  A part:

    * `:type` - its content type, in lowercase (`"text/plain"` when it
      has none, as RFC 2045 says).
    * `:params` - the content type's parameters (`"charset"`,
      `"boundary"`, `"name"`), decoded.
    * `:disposition` - `"attachment"`, `"inline"`, or nil when it has none,
      and `:disposition_params` (`"filename"`, decoded).
    * `:encoding` - its `Content-Transfer-Encoding`, in lowercase:
      `"base64"`, `"quoted-printable"`, `"7bit"`, `"8bit"`, `"binary"`.
    * `:content_id` - its `Content-ID`, without the angle brackets: what
      an HTML part's `cid:` points to.
    * `:headers` - all its headers (`Letterbox.MIME.Header.parse/1`).
    * `:body` - its body, still encoded, a sub-binary of the email.
    * `:parts` - the parts of a multipart, and the one email of a
      `message/rfc822` (a forwarded email, attached).
    * `:path` - where it is: `[]` for the email, `[1, 0]` for the first
      part of the second.
  """
  @type t :: %__MODULE__{
          type: String.t(),
          params: %{String.t() => String.t()},
          disposition: String.t() | nil,
          disposition_params: %{String.t() => String.t()},
          encoding: String.t(),
          content_id: String.t() | nil,
          headers: [Header.t()],
          body: binary(),
          parts: [t()],
          path: [non_neg_integer()]
        }

  @max_depth 20
  @max_parts 1_000

  @doc """
  The structure of an email, `raw` as it came (RFC 5322).

  Options: `:max_depth` (20) and `:max_parts` (1,000).
  """
  @spec parse(binary(), keyword()) :: t()
  def parse(raw, opts \\ []) when is_binary(raw) do
    limits = %{
      depth: Keyword.get(opts, :max_depth, @max_depth),
      parts: :counters.new(1, []),
      max_parts: Keyword.get(opts, :max_parts, @max_parts)
    }

    part(raw, [], "text/plain", limits)
  end

  defp part(raw, path, default_type, limits) do
    {header_block, body} = split_head(raw)
    headers = Header.parse(header_block)
    {type, params} = content_type(Header.get(headers, "content-type"), default_type)
    {disposition, disposition_params} = Header.params(Header.get(headers, "content-disposition"))

    part = %__MODULE__{
      type: type,
      params: params,
      disposition: disposition,
      disposition_params: disposition_params,
      encoding: encoding(Header.get(headers, "content-transfer-encoding")),
      content_id: content_id(Header.get(headers, "content-id")),
      headers: headers,
      body: body,
      path: path
    }

    :counters.add(limits.parts, 1, 1)
    children(part, limits)
  end

  # The headers and the body: before and after the first empty line. A
  # part whose first line is empty, or an email that starts with its body,
  # has no headers.
  defp split_head(<<"\r\n", body::binary>>), do: {"", body}
  defp split_head(<<"\n", body::binary>>), do: {"", body}

  defp split_head(raw) do
    case :binary.match(raw, ["\r\n\r\n", "\n\n", "\r\n\n", "\n\r\n"]) do
      {start, length} ->
        {binary_part(raw, 0, start),
         binary_part(raw, start + length, byte_size(raw) - start - length)}

      :nomatch ->
        if header_like?(raw), do: {raw, ""}, else: {"", raw}
    end
  end

  defp header_like?(raw), do: Regex.match?(~r/\A[!-9;-~]+:/, raw)

  defp content_type(nil, default), do: {default, %{}}

  defp content_type(value, default) do
    case Header.params(value) do
      {type, params} when is_binary(type) ->
        if String.match?(type, ~r{\A[\w.+-]+/[\w.+-]+\z}),
          do: {type, params},
          else: {default, params}

      {nil, params} ->
        {default, params}
    end
  end

  defp encoding(nil), do: "7bit"
  defp encoding(value), do: value |> String.trim() |> String.downcase()

  defp content_id(nil), do: nil

  defp content_id(value) do
    case value |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">") do
      "" -> nil
      id -> id
    end
  end

  defp children(
         %{type: "multipart/" <> subtype, params: %{"boundary" => boundary}} = part,
         limits
       )
       when boundary != "" do
    if within?(part, limits) do
      default = if subtype == "digest", do: "message/rfc822", else: "text/plain"

      parts =
        part.body
        |> split_parts(boundary)
        |> Enum.with_index()
        |> Enum.map(fn {raw, index} -> part(raw, part.path ++ [index], default, limits) end)

      %{part | parts: parts}
    else
      part
    end
  end

  defp children(%{type: "message/rfc822", encoding: encoding} = part, limits)
       when encoding in ["7bit", "8bit", "binary"] do
    if within?(part, limits),
      do: %{part | parts: [part(part.body, part.path ++ [0], "text/plain", limits)]},
      else: part
  end

  defp children(part, _limits), do: part

  defp within?(part, limits),
    do: length(part.path) < limits.depth and :counters.get(limits.parts, 1) < limits.max_parts

  # The bodies between the boundary lines of a multipart: a line that is
  # `--boundary` (and spaces) opens one, `--boundary--` ends them all, and
  # the line break before a boundary line is the boundary's. A multipart
  # that never ends ends where its body does.
  defp split_parts(body, boundary) do
    delimiter = "--" <> boundary

    body
    |> :binary.matches(delimiter)
    |> Enum.map(fn {start, length} -> {start, start + length} end)
    |> Enum.filter(fn {start, finish} ->
      line_start?(body, start) and boundary_end?(body, finish)
    end)
    |> parts_between(body)
  end

  defp line_start?(_body, 0), do: true
  defp line_start?(body, start), do: :binary.at(body, start - 1) == ?\n

  defp boundary_end?(body, finish) when finish == byte_size(body), do: true

  defp boundary_end?(body, finish) do
    case binary_part(body, finish, min(2, byte_size(body) - finish)) do
      "--" <> _ -> true
      <<c, _::binary>> -> c in [?\r, ?\n, ?\s, ?\t]
    end
  end

  defp parts_between([], _body), do: []

  defp parts_between(delimiters, body) do
    delimiters
    |> Enum.chunk_every(2, 1)
    |> Enum.reduce_while([], fn [{_start, finish} | next], acc ->
      if closing?(body, finish),
        do: {:halt, acc},
        else: {:cont, [part_after(body, finish, next) | acc]}
    end)
    |> Enum.reverse()
  end

  # The body after a boundary line, to the line break before the next one.
  defp part_after(body, finish, next) do
    from = after_line(body, finish)

    to =
      case next do
        [{next_start, _next_finish}] -> before_line_break(body, next_start)
        [] -> byte_size(body)
      end

    binary_part(body, from, max(to - from, 0))
  end

  defp closing?(body, finish),
    do: byte_size(body) - finish >= 2 and binary_part(body, finish, 2) == "--"

  # Past the rest of the boundary's line.
  defp after_line(body, from) do
    case :binary.match(body, "\n", scope: {from, byte_size(body) - from}) do
      {newline, 1} -> newline + 1
      :nomatch -> byte_size(body)
    end
  end

  defp before_line_break(body, at) do
    cond do
      at >= 2 and binary_part(body, at - 2, 2) == "\r\n" -> at - 2
      at >= 1 and binary_part(body, at - 1, 1) == "\n" -> at - 1
      true -> at
    end
  end

  @doc """
  Every part with no parts of its own (the texts, images, files), in the
  order a reader meets them, a `message/rfc822` included as one.
  """
  @spec leaves(t()) :: [t()]
  def leaves(%__MODULE__{type: "multipart/" <> _, parts: [_ | _] = parts}),
    do: Enum.flat_map(parts, &leaves/1)

  def leaves(%__MODULE__{} = part), do: [part]

  @doc "A part's body, decoded from its transfer encoding: the bytes it carries."
  @spec decode(t()) :: binary()
  def decode(%__MODULE__{encoding: "base64", body: body}), do: base64_all(body)
  def decode(%__MODULE__{encoding: "quoted-printable", body: body}), do: quoted_printable(body)
  def decode(%__MODULE__{body: body}), do: body

  @doc """
  A text part's body in UTF-8, from its charset, with its line breaks as
  `\\n`: `{:ok, text}`, or `{:lossy, text}` when bytes of it could not be
  read (see `Letterbox.Charset`).
  """
  @spec text(t()) :: {:ok, String.t()} | {:lossy, String.t()}
  def text(%__MODULE__{} = part) do
    {complete, text} = part |> decode() |> Charset.decode(part.params["charset"])
    {complete, String.replace(text, "\r\n", "\n")}
  end

  @doc """
  A part's body, decoded, as a stream of chunks: for a large attachment,
  written to a file as it is decoded. `:chunk` is how many bytes of the
  encoded body each chunk is decoded from (64 KB).
  """
  @spec stream(t(), keyword()) :: Enumerable.t()
  def stream(%__MODULE__{} = part, opts \\ []) do
    chunk = Keyword.get(opts, :chunk, 65_536)

    case part.encoding do
      "base64" -> base64_stream(part.body, chunk)
      "quoted-printable" -> qp_stream(part.body, chunk)
      _other -> slices(part.body, chunk)
    end
  end

  defp slices(body, chunk) do
    Stream.unfold(0, fn
      at when at >= byte_size(body) -> nil
      at -> {binary_part(body, at, min(chunk, byte_size(body) - at)), at + chunk}
    end)
  end

  # Base64, decoded a slice at a time: the characters of the alphabet are
  # kept (line breaks and stray bytes go), four at a time, and what is left
  # of a slice goes with the next.
  defp base64_stream(body, chunk) do
    body
    |> slices(chunk)
    |> Stream.transform(
      fn -> "" end,
      fn slice, carry ->
        clean = carry <> base64_alphabet(slice)
        whole = byte_size(clean) - rem(byte_size(clean), 4)
        <<now::binary-size(^whole), later::binary>> = clean
        {[base64_decode(now)], later}
      end,
      fn carry -> {[base64_decode(pad(carry))], ""} end,
      fn _carry -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
  end

  defp base64_all(body), do: body |> base64_alphabet() |> pad() |> base64_decode()

  defp base64_alphabet(bytes) do
    for <<c <- bytes>>, c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?+, ?/],
      into: "",
      do: <<c>>
  end

  # A last group of 2 or 3 characters is padded; a single one is no byte.
  defp pad(rest) when rem(byte_size(rest), 4) == 1,
    do: pad(binary_part(rest, 0, byte_size(rest) - 1))

  defp pad(rest), do: rest <> String.duplicate("=", rem(4 - rem(byte_size(rest), 4), 4))

  defp base64_decode(""), do: ""

  defp base64_decode(text) do
    case Base.decode64(text, padding: true) do
      {:ok, bytes} -> bytes
      :error -> ""
    end
  end

  # Quoted-printable a line at a time: a slice ends after its last line
  # break, so `=` and its two digits are never cut apart.
  defp qp_stream(body, chunk) do
    body
    |> slices(chunk)
    |> Stream.transform(
      fn -> "" end,
      fn slice, carry ->
        text = carry <> slice

        case :binary.matches(text, "\n") do
          [] ->
            {[], text}

          matches ->
            {last, 1} = List.last(matches)
            whole = last + 1
            <<now::binary-size(^whole), later::binary>> = text
            {[quoted_printable(now)], later}
        end
      end,
      fn carry -> {[quoted_printable(carry)], ""} end,
      fn _carry -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
  end

  @doc false
  # RFC 2045's quoted-printable: `=XX` is a byte, `=` at the end of a line
  # joins it to the next, and anything else is itself (a stray `=` too).
  @spec quoted_printable(binary()) :: binary()
  def quoted_printable(text), do: qp(text, [])

  # The text between two `=` is copied as it is, a sub-binary at a time.
  defp qp(text, acc) do
    case :binary.match(text, "=") do
      :nomatch ->
        IO.iodata_to_binary(Enum.reverse([text | acc]))

      {at, 1} ->
        before = binary_part(text, 0, at)
        escape(binary_part(text, at + 1, byte_size(text) - at - 1), [before | acc])
    end
  end

  defp escape(<<?\r, ?\n, rest::binary>>, acc), do: qp(rest, acc)
  defp escape(<<?\n, rest::binary>>, acc), do: qp(rest, acc)

  defp escape(<<a, b, rest::binary>> = all, acc) do
    if hex?(a) and hex?(b),
      do: qp(rest, [String.to_integer(<<a, b>>, 16) | acc]),
      else: qp(all, ["=" | acc])
  end

  defp escape(rest, acc), do: qp(rest, ["=" | acc])

  defp hex?(c), do: c in ?0..?9 or c in ?A..?F or c in ?a..?f
end
