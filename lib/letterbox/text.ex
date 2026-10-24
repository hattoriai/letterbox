defmodule Letterbox.Text do
  @moduledoc false
  # Plain text from HTML, for a message that came with HTML only: what a
  # reader would see, without its tags, styles and scripts, its paragraphs
  # and line breaks as new lines, its entities as characters. Not a
  # renderer: enough to read it, route it and find a reply in it.

  @blocks ~w(p div li tr table h1 h2 h3 h4 h5 h6 blockquote pre ul ol section article header footer)

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "copy" => "©",
    "reg" => "®",
    "euro" => "€",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "bull" => "•",
    "middot" => "·",
    "laquo" => "«",
    "raquo" => "»"
  }

  @spec from_html(String.t()) :: String.t()
  def from_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<(head|style|script|title)\b[^>]*>.*?<\/\1\s*>/is, "")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(#{Enum.join(@blocks, "|")})\s*>/i, "\n")
    |> String.replace(~r/<(#{Enum.join(@blocks, "|")})\b[^>]*>/i, "\n")
    |> String.replace(~r/<[^>]*>/s, "")
    |> entities()
    |> String.replace(~r/[ \t\x{00A0}]+/u, " ")
    |> String.replace(~r/ *\n */, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/, text, fn all, entity ->
      case entity do
        "#x" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#X" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#" <> decimal -> codepoint(Integer.parse(decimal), all)
        name -> Map.get(@entities, String.downcase(name), all)
      end
    end)
  end

  defp codepoint({code, ""}, _all) when code in 1..0x10FFFF and code not in 0xD800..0xDFFF,
    do: <<code::utf8>>

  defp codepoint(_other, all), do: all
end
