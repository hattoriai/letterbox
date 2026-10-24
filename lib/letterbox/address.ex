defmodule Letterbox.Address do
  @moduledoc """
  An email address and the name that came with it.

      Letterbox.Address.parse_list(~s("Martínez, José" <jose+photos@Example.com>, ana@example.com))
      #=> [%Letterbox.Address{name: "Martínez, José", address: "jose+photos@example.com"},
      #    %Letterbox.Address{name: nil, address: "ana@example.com"}]

  The domain is in lowercase; the local part stays as it came (RFC 5321
  lets a server tell `Ana` from `ana`, though few do: `local/1` and
  `matches?/2` compare it in lowercase). A sub-address, the part after
  `+` (`jose+photos@`), is `tag/1`.

  Lists are read as mail clients write them: names quoted or not, with
  encoded words (`=?utf-8?Q?Jos=C3=A9?=`), comments (`ana@example.com
  (Ana)`, a name when there is no other), groups (`Team: a@x, b@x;`,
  `undisclosed-recipients:;`), and commas inside quotes.
  """

  alias Letterbox.MIME.Header

  @enforce_keys [:address]
  defstruct [:name, :address]

  @type t :: %__MODULE__{name: String.t() | nil, address: String.t()}

  @doc "The addresses of a header's value (`From`, `To`, `Cc`, …), in their order."
  @spec parse_list(String.t() | nil) :: [t()]
  def parse_list(nil), do: []

  def parse_list(value) when is_binary(value) do
    value
    |> ungroup()
    |> Header.split_outside_quotes(?,)
    |> Enum.flat_map(&mailbox/1)
  end

  @doc "The first address of a header's value, or nil."
  @spec parse(String.t() | nil) :: t() | nil
  def parse(value), do: value |> parse_list() |> List.first()

  # A group's name and its closing `;` go: `Team: a@x, b@x;` is `a@x, b@x`.
  defp ungroup(value) do
    value
    |> Header.split_outside_quotes(?;)
    |> Enum.map_join(",", fn part ->
      case Header.split_outside_quotes(part, ?:) do
        [part] ->
          part

        [before | members] ->
          # The group's name is what follows the last comma before the `:`.
          before
          |> Header.split_outside_quotes(?,)
          |> Enum.drop(-1)
          |> Enum.concat([Enum.join(members, ":")])
          |> Enum.join(",")
      end
    end)
  end

  defp mailbox(text) do
    text = String.trim(text)

    case Regex.run(~r/\A(.*)<([^<>]*)>\s*(\(.*\))?\s*\z/s, text) do
      [_all, name, address | _comment] -> new(address, name)
      nil -> bare(text)
    end
  end

  # `ana@example.com (Ana)`: the address, and the comment as its name.
  defp bare(text) do
    {address, comment} =
      case Regex.run(~r/\A([^()\s]+)\s*\((.*)\)\s*\z/s, text) do
        [_all, address, comment] -> {address, comment}
        nil -> {text, nil}
      end

    new(address, comment)
  end

  defp new(address, name) do
    address = address |> String.trim() |> String.trim("\"")

    case normalize(address) do
      nil -> []
      address -> [%__MODULE__{address: address, name: display_name(name)}]
    end
  end

  defp normalize(address) do
    case String.split(address, "@") do
      [local, domain] when local != "" and domain != "" ->
        if String.contains?(local <> domain, [" ", "<", ">", ","]),
          do: nil,
          else: local <> "@" <> String.downcase(domain)

      _other ->
        nil
    end
  end

  defp display_name(nil), do: nil

  defp display_name(name) do
    name =
      name
      |> String.trim()
      |> unquote_name()
      |> Header.decode()
      |> String.trim()

    if name == "", do: nil, else: name
  end

  defp unquote_name(<<?", rest::binary>>) do
    rest |> String.replace_suffix("\"", "") |> String.replace(~r/\\(.)/s, "\\1")
  end

  defp unquote_name(name), do: name

  @doc "The local part, before the `@`, in lowercase."
  @spec local(t()) :: String.t()
  def local(%__MODULE__{address: address}),
    do: address |> String.split("@") |> hd() |> String.downcase()

  @doc "The domain, after the `@`."
  @spec domain(t()) :: String.t()
  def domain(%__MODULE__{address: address}), do: address |> String.split("@") |> List.last()

  @doc """
  The sub-address: what follows the first `+` of the local part
  (`photos+abc123@` gives `"abc123"`), or nil.
  """
  @spec tag(t()) :: String.t() | nil
  def tag(%__MODULE__{} = address) do
    case address |> local_as_written() |> :binary.split("+") do
      [_base, tag] when tag != "" -> tag
      _other -> nil
    end
  end

  @doc "The address without its sub-address, in lowercase: `photos@in.example.com`."
  @spec base(t()) :: String.t()
  def base(%__MODULE__{} = address) do
    [base | _tag] = address |> local() |> :binary.split("+")
    base <> "@" <> domain(address)
  end

  @doc """
  Whether the address is `other` (an address, as a string or a struct),
  in lowercase, and with or without a sub-address when `other` has none.
  """
  @spec matches?(t(), t() | String.t()) :: boolean()
  def matches?(%__MODULE__{} = address, %__MODULE__{address: other}), do: matches?(address, other)

  def matches?(%__MODULE__{address: address} = struct, other) when is_binary(other) do
    other = String.downcase(other)
    String.downcase(address) == other or base(struct) == other
  end

  defp local_as_written(%__MODULE__{address: address}), do: address |> String.split("@") |> hd()

  defimpl String.Chars do
    def to_string(%{name: nil, address: address}), do: address

    def to_string(%{name: name, address: address}) do
      if String.match?(name, ~r/\A[\w .'-]+\z/u),
        do: "#{name} <#{address}>",
        else: ~s("#{String.replace(name, ~r/(["\\])/, "\\\\\\1")}" <#{address}>)
    end
  end
end
