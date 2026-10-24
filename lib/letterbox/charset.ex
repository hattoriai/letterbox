defmodule Letterbox.Charset do
  @moduledoc """
  The text of an email in UTF-8, whatever charset it was written in.

  Letterbox knows UTF-8 and the single-byte encodings of the
  [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/), as
  browsers do: Windows-1250 to 1258, the ISO-8859 family, KOI8-R and
  KOI8-U, Mac Roman and others, under every label WHATWG lists. Like a
  browser, it reads `iso-8859-1` and `us-ascii` as Windows-1252, which they
  nearly always are in real email: the `€` and the curly quotes of
  Outlook's Latin-1 are bytes Latin-1 does not have.

  An encoding of several bytes a character (Shift_JIS, ISO-2022-JP, GBK,
  Big5, EUC-KR) goes to a module of the app's, when it has one:

      config :letterbox, charsets: MyApp.Charsets

      defmodule MyApp.Charsets do
        @behaviour Letterbox.Charset

        @impl true
        def decode(bytes, "shift_jis"), do: MyApp.Iconv.convert(bytes, "SHIFT_JIS", "UTF-8")
        def decode(_bytes, _label), do: :error
      end

  What no one can read is given with each unknown byte as `U+FFFD`, and
  `decode/2` says so (`:lossy`), so a message can tell that its text is
  not all there.
  """

  alias Letterbox.Charset.Tables

  @doc """
  Decodes `bytes` of the encoding `label` (lowercase, trimmed): `{:ok,
  utf8}`, or `:error` for a label the module does not know.
  """
  @callback decode(bytes :: binary(), label :: String.t()) :: {:ok, String.t()} | :error

  @utf8 ~w(utf-8 utf8 unicode-1-1-utf-8 unicode11utf8 unicode20utf8 x-unicode20utf8)

  @doc """
  `bytes` in UTF-8: `{:ok, text}` when every byte was read, `{:lossy,
  text}` when some became `U+FFFD` (bytes the encoding does not have, or an
  encoding no one knows).
  """
  @spec decode(binary(), String.t() | nil) :: {:ok, String.t()} | {:lossy, String.t()}
  def decode(bytes, label) when is_binary(bytes) do
    label = normalize(label)

    cond do
      ascii?(bytes) -> {:ok, bytes}
      label in @utf8 -> utf8(bytes)
      label == nil -> unlabeled(bytes)
      encoding = Tables.encoding(label) -> {:ok, single_byte(bytes, Tables.upper_half(encoding))}
      true -> other(bytes, label)
    end
  end

  @doc "`decode/2`'s text, lossy or not."
  @spec to_utf8(binary(), String.t() | nil) :: String.t()
  def to_utf8(bytes, label) do
    {_complete, text} = decode(bytes, label)
    text
  end

  @doc """
  Whether Letterbox reads `label` itself (UTF-8, or one of WHATWG's
  single-byte encodings), without the app's module.
  """
  @spec known?(String.t() | nil) :: boolean()
  def known?(label) do
    label = normalize(label)
    label in @utf8 or Tables.encoding(label) != nil
  end

  defp normalize(nil), do: nil
  defp normalize(label), do: label |> String.trim() |> String.trim("\"") |> String.downcase()

  defp ascii?(<<byte, rest::binary>>) when byte < 0x80, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_bytes), do: false

  # Valid UTF-8 as it is; an invalid byte becomes U+FFFD, and the rest is
  # read on.
  defp utf8(bytes) do
    if String.valid?(bytes), do: {:ok, bytes}, else: {:lossy, scrub(bytes, [])}
  end

  # Text that names no charset (a raw header, a part without one): UTF-8
  # when it is, else, most often, Windows-1252.
  defp unlabeled(bytes) do
    if String.valid?(bytes),
      do: {:ok, bytes},
      else: {:ok, single_byte(bytes, Tables.upper_half("windows-1252"))}
  end

  defp scrub(bytes, acc) do
    case :unicode.characters_to_binary(bytes) do
      good when is_binary(good) ->
        IO.iodata_to_binary(Enum.reverse([good | acc]))

      {_error_or_incomplete, good, <<_bad, rest::binary>>} ->
        scrub(rest, ["�", good | acc])

      {_error_or_incomplete, good, <<>>} ->
        IO.iodata_to_binary(Enum.reverse([good | acc]))
    end
  end

  defp single_byte(bytes, table) do
    for <<byte <- bytes>>, into: "" do
      if byte < 0x80, do: <<byte>>, else: <<elem(table, byte - 0x80)::utf8>>
    end
  end

  defp other(bytes, label) do
    with module when is_atom(module) and module != nil <-
           Application.get_env(:letterbox, :charsets),
         {:ok, text} when is_binary(text) <- module.decode(bytes, label),
         true <- String.valid?(text) do
      {:ok, text}
    else
      _unknown -> {:lossy, unknown(bytes)}
    end
  end

  # An encoding no one knows: its ASCII as it is, the rest U+FFFD, one for
  # each run of other bytes.
  defp unknown(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.chunk_by(&(&1 < 0x80))
    |> Enum.map(fn [byte | _] = run -> if byte < 0x80, do: run, else: "�" end)
    |> IO.iodata_to_binary()
  end
end
