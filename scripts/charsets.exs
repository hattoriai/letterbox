# Writes lib/letterbox/charset/tables.ex: the legacy single-byte encodings
# of the WHATWG Encoding Standard, with their labels, from WHATWG's own
# files (https://github.com/whatwg/encoding): encodings.json, and
# index-<name>.txt for each.
#
#     mix run scripts/charsets.exs
#
# Each table is the upper half of its encoding, bytes 0x80 to 0xFF, as code
# points; a byte the index does not give is U+FFFD.

base = "https://raw.githubusercontent.com/whatwg/encoding/main/"

encodings =
  Req.get!(base <> "encodings.json", decode_body: false).body
  |> JSON.decode!()
  |> Enum.find(&(&1["heading"] == "Legacy single-byte encodings"))
  |> Map.fetch!("encodings")

# The labels of windows-1252 (iso-8859-1, us-ascii, …) are in "The
# Encoding" section, not with the legacy ones.
encodings =
  [%{"name" => "windows-1252", "labels" => []} | encodings]
  |> Enum.group_by(& &1["name"], & &1["labels"])
  |> Enum.map(fn {name, labels} -> %{"name" => name, "labels" => List.flatten(labels)} end)

all_labels =
  Req.get!(base <> "encodings.json", decode_body: false).body
  |> JSON.decode!()
  |> Enum.flat_map(& &1["encodings"])
  |> Map.new(&{String.downcase(&1["name"]), &1["labels"]})

# ISO-8859-8-I is read with ISO-8859-8's index (it has none of its own).
index = fn
  "iso-8859-8-i" -> "iso-8859-8"
  name -> name
end

upper_half = fn name ->
  points =
    Req.get!(base <> "index-#{index.(name)}.txt", decode_body: false).body
    |> String.split("\n")
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Map.new(fn line ->
      [pointer, "0x" <> hex | _] =
        String.split(line, "\t", trim: true) |> Enum.map(&String.trim/1)

      {String.to_integer(pointer), String.to_integer(hex, 16)}
    end)

  for pointer <- 0..127, do: Map.get(points, pointer, 0xFFFD)
end

names = encodings |> Enum.map(&String.downcase(&1["name"])) |> Enum.sort()

labels =
  for name <- names, label <- Map.get(all_labels, name, []), do: {label, name}

tables = for name <- names, do: {name, upper_half.(name)}

# Code points as Unicode writes them: 0x20AC.
hex = fn point -> "0x" <> String.pad_leading(Integer.to_string(point, 16), 4, "0") end

source = """
defmodule Letterbox.Charset.Tables do
  @moduledoc false
  # Written by scripts/charsets.exs from WHATWG's encodings.json and
  # index files: the legacy single-byte encodings of the Encoding Standard,
  # bytes 0x80 to 0xFF as code points. Do not edit; run the script.

  @labels %{
#{labels |> Enum.sort() |> Enum.uniq() |> Enum.map_join(",\n", fn {label, name} -> ~s(    "#{label}" => "#{name}") end)}
  }

  @doc false
  # The encoding of a label (lowercase, trimmed), or nil.
  def encoding(label), do: Map.get(@labels, label)

  @doc false
  # The upper half of a single-byte encoding, a tuple of 128 code points.
#{Enum.map_join(tables, "\n", fn {name, points} -> ~s(  def upper_half("#{name}"\), do: {#{Enum.map_join(points, ", ", &hex.(&1))}}) end)}
  def upper_half(_name), do: nil
end
"""

File.write!("lib/letterbox/charset/tables.ex", source)
Mix.shell().info("Wrote #{length(tables)} encodings and #{length(labels)} labels.")
