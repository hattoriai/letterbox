defmodule Letterbox.MIME.Header do
  @moduledoc """
  The headers of an email or of one of its parts (RFC 5322 and MIME), read
  as mail clients write them, not only as the RFCs say they should.

    * `parse/1` - a block of headers as `{name, value}` pairs, in their
      order: names in lowercase, values unfolded and not yet decoded.
    * `decode/1` - a value's encoded words (RFC 2047,
      `=?utf-8?Q?Jos=C3=A9?=`) in UTF-8, adjacent ones of one charset
      joined before they are read, so a character split across two words
      survives; raw 8-bit text (RFC 6532) as UTF-8, else as Windows-1252.
    * `params/1` - a structured value (`Content-Type`,
      `Content-Disposition`): its value and its parameters, with RFC 2231's
      (`filename*=utf-8''praia%20%C3%A0%20tarde.jpg`, and the parts of a
      long one, `filename*0*`, `filename*1*`) and the encoded words that
      Outlook and Gmail put in quoted ones.
  """

  alias Letterbox.Charset

  @typedoc "A header: its name in lowercase, and its value as it came, unfolded."
  @type t :: {String.t(), String.t()}

  @doc """
  The headers of a block of header lines (`CRLF` or `LF`), unfolded. A
  line that is not a header and does not continue one is left out.
  """
  @spec parse(binary()) :: [t()]
  def parse(block) when is_binary(block) do
    block
    |> String.split(["\r\n", "\n"])
    |> unfold([])
    |> Enum.flat_map(&field/1)
  end

  defp unfold([], acc), do: Enum.reverse(acc)

  defp unfold([<<space, _::binary>> = line | rest], [previous | acc]) when space in [?\s, ?\t],
    do: unfold(rest, [previous <> line | acc])

  defp unfold([line | rest], acc), do: unfold(rest, [line | acc])

  defp field(line) do
    case :binary.split(line, ":") do
      [name, value] ->
        name = String.trim(name)

        if name != "" and printable_name?(name),
          do: [{String.downcase(name), String.trim(value)}],
          else: []

      [_no_colon] ->
        []
    end
  end

  defp printable_name?(name),
    do: for(<<c <- name>>, reduce: true, do: (ok -> ok and c in 33..126))

  @doc "The first value of `name` (lowercase) in `headers`, or nil."
  @spec get([t()], String.t()) :: String.t() | nil
  def get(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  @doc "Every value of `name` (lowercase) in `headers`, in their order."
  @spec get_all([t()], String.t()) :: [String.t()]
  def get_all(headers, name), do: for({^name, value} <- headers, do: value)

  @doc """
  A header's value in UTF-8: its encoded words decoded, and the spaces
  between two of them taken out, as RFC 2047 says.
  """
  @spec decode(String.t() | nil) :: String.t() | nil
  def decode(nil), do: nil

  def decode(value) when is_binary(value) do
    value
    |> tokens([])
    |> join_words([])
    |> Enum.map_join(fn
      {:text, text} -> Charset.to_utf8(text, nil)
      {:word, charset, bytes} -> Charset.to_utf8(bytes, charset)
    end)
  end

  @encoded_word ~r/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/

  # The value as text and encoded words, in their order.
  defp tokens(value, acc) do
    case Regex.run(@encoded_word, value, return: :index) do
      nil ->
        Enum.reverse(text(value, acc))

      [{start, length}, charset, encoding, encoded] ->
        <<before::binary-size(^start), _word::binary-size(^length), rest::binary>> = value
        charset = value |> slice(charset) |> String.split("*") |> hd()
        bytes = word(slice(value, encoding), slice(value, encoded))
        tokens(rest, [{:word, charset, bytes} | text(before, acc)])
    end
  end

  defp slice(value, {start, length}), do: binary_part(value, start, length)

  defp text("", acc), do: acc
  defp text(text, acc), do: [{:text, text} | acc]

  defp word(encoding, encoded) when encoding in ["B", "b"], do: base64(encoded)
  defp word(_q, encoded), do: q(encoded, [])

  defp base64(encoded) do
    encoded = String.replace(encoded, ~r/[^A-Za-z0-9+\/]/, "")
    padded = encoded <> String.duplicate("=", rem(4 - rem(byte_size(encoded), 4), 4))

    case Base.decode64(padded) do
      {:ok, bytes} -> bytes
      :error -> encoded
    end
  end

  defp q(<<?_, rest::binary>>, acc), do: q(rest, [?\s | acc])

  defp q(<<?=, a, b, rest::binary>> = all, acc) do
    case Integer.parse(<<a, b>>, 16) do
      {byte, ""} -> q(rest, [byte | acc])
      _other -> q(binary_part(all, 1, byte_size(all) - 1), [?= | acc])
    end
  end

  defp q(<<c, rest::binary>>, acc), do: q(rest, [c | acc])
  defp q(<<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  # Spaces between two encoded words go; two words of one charset are one,
  # so a character whose bytes the encoder split is whole again.
  defp join_words([{:word, cs, a}, {:text, space}, {:word, cs2, b} | rest], acc)
       when is_binary(space) do
    if blank?(space),
      do: join_words([{:word, cs, a}, {:word, cs2, b} | rest], acc),
      else: join_words([{:text, space}, {:word, cs2, b} | rest], [{:word, cs, a} | acc])
  end

  defp join_words([{:word, cs, a}, {:word, cs2, b} | rest], acc) do
    if String.downcase(cs) == String.downcase(cs2),
      do: join_words([{:word, cs, a <> b} | rest], acc),
      else: join_words([{:word, cs2, b} | rest], [{:word, cs, a} | acc])
  end

  defp join_words([token | rest], acc), do: join_words(rest, [token | acc])
  defp join_words([], acc), do: Enum.reverse(acc)

  defp blank?(text), do: String.trim(text) == ""

  @doc """
  A structured value and its parameters: `{"multipart/mixed",
  %{"boundary" => "…"}}`. The value is in lowercase and so are the
  parameters' names; their values are decoded (RFC 2231, RFC 2047, quoted
  strings) to UTF-8.
  """
  @spec params(String.t() | nil) :: {String.t() | nil, %{String.t() => String.t()}}
  def params(nil), do: {nil, %{}}

  def params(value) when is_binary(value) do
    [main | rest] = split_outside_quotes(value, ?;)
    main = main |> String.trim() |> String.downcase()

    params =
      rest
      |> Enum.flat_map(&param/1)
      |> continuations()

    {if(main == "", do: nil, else: main), params}
  end

  defp param(text) do
    case :binary.split(String.trim(text), "=") do
      [name, value] when name != "" ->
        [{name |> String.trim() |> String.downcase(), value |> String.trim() |> unquote_value()}]

      _other ->
        []
    end
  end

  defp unquote_value(<<?", rest::binary>>) do
    rest
    |> String.replace_suffix("\"", "")
    |> String.replace(~r/\\(.)/s, "\\1")
  end

  defp unquote_value(value), do: value

  # RFC 2231: `name*` (charset'language'%XX…), and `name*0`, `name*1*`…,
  # the parts of one long value, joined in their order. Everything else as
  # it is, with its encoded words decoded.
  defp continuations(pairs) do
    {extended, plain} =
      Enum.split_with(pairs, fn {name, _value} -> String.contains?(name, "*") end)

    plain = for {name, value} <- plain, into: %{}, do: {name, decode(value)}

    extended
    |> Enum.group_by(fn {name, _value} -> name |> String.split("*") |> hd() end)
    |> Enum.reduce(plain, fn {name, segments}, acc -> Map.put(acc, name, joined(segments)) end)
  end

  defp joined(segments) do
    segments =
      segments
      |> Enum.map(fn {name, value} ->
        [_base | marks] = String.split(name, "*")
        {index(marks), List.last(marks) == "" or marks == [""], value}
      end)
      |> Enum.sort_by(fn {index, _encoded?, _value} -> index end)

    {charset, bytes} =
      Enum.reduce(segments, {nil, ""}, fn {index, encoded?, value}, {charset, acc} ->
        cond do
          encoded? and index == 0 ->
            {charset, value} = charset_and_value(value)
            {charset, acc <> percent_decode(value)}

          encoded? ->
            {charset, acc <> percent_decode(value)}

          true ->
            {charset, acc <> value}
        end
      end)

    Charset.to_utf8(bytes, charset)
  end

  defp index([""]), do: 0
  defp index([number | _]), do: String.to_integer(number)

  # `utf-8'pt'praia%20…`: the charset, the language (left), the value.
  defp charset_and_value(value) do
    case String.split(value, "'", parts: 3) do
      [charset, _language, rest] -> {if(charset == "", do: nil, else: charset), rest}
      _other -> {nil, value}
    end
  rescue
    ArgumentError -> {nil, value}
  end

  defp percent_decode(value) do
    URI.decode(value)
  rescue
    ArgumentError -> value
  end

  @doc false
  # `value` split at each `separator` that is not in a quoted string, in
  # angle brackets or in a comment.
  @spec split_outside_quotes(String.t(), char()) :: [String.t()]
  def split_outside_quotes(value, separator) do
    {parts, current, _state} =
      for <<c <- value>>,
        reduce: {[], [], %{quote: false, escape: false, angle: 0, comment: 0}} do
        {parts, current, state} -> step(c, separator, parts, current, state)
      end

    Enum.reverse([current |> Enum.reverse() |> :erlang.list_to_binary() | parts])
  end

  defp step(c, _separator, parts, current, %{escape: true} = state),
    do: {parts, [c | current], %{state | escape: false}}

  defp step(?\\, _separator, parts, current, %{quote: true} = state),
    do: {parts, [?\\ | current], %{state | escape: true}}

  defp step(?", _separator, parts, current, %{comment: 0} = state),
    do: {parts, [?" | current], %{state | quote: not state.quote}}

  defp step(c, separator, parts, current, %{quote: false, angle: 0, comment: 0} = state)
       when c == separator,
       do: {[current |> Enum.reverse() |> :erlang.list_to_binary() | parts], [], state}

  defp step(?<, _separator, parts, current, %{quote: false, comment: 0} = state),
    do: {parts, [?< | current], %{state | angle: state.angle + 1}}

  defp step(?>, _separator, parts, current, %{quote: false, comment: 0} = state),
    do: {parts, [?> | current], %{state | angle: max(state.angle - 1, 0)}}

  defp step(?(, _separator, parts, current, %{quote: false} = state),
    do: {parts, [?( | current], %{state | comment: state.comment + 1}}

  defp step(?), _separator, parts, current, %{quote: false} = state),
    do: {parts, [?) | current], %{state | comment: max(state.comment - 1, 0)}}

  defp step(c, _separator, parts, current, state), do: {parts, [c | current], state}
end
