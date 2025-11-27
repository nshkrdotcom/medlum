defmodule Lumainus.Conversion.ProcessingProfile do
  @moduledoc """
  User-facing processing profiles that abstract backend selection.

  - `:standard` — Uses local CPU backends, free tier
  - `:enhanced` — Uses GPU backends (local or cloud), premium tier

  ## Usage

      iex> ProcessingProfile.all()
      [:standard, :enhanced]

      iex> ProcessingProfile.valid?(:standard)
      true

      iex> ProcessingProfile.default_timeout_ms(:standard)
      900_000

      iex> ProcessingProfile.max_timeout_ms()
      1_200_000
  """

  @type t :: :standard | :enhanced

  @profiles [:standard, :enhanced]

  # 15 minutes for standard (CPU backends)
  @standard_timeout_ms 900_000

  # 20 minutes for enhanced (GPU backends, may need provisioning)
  @enhanced_timeout_ms 1_200_000

  # Absolute maximum timeout
  @max_timeout_ms 1_200_000

  @doc """
  Returns list of all available processing profiles.
  """
  @spec all() :: [t()]
  def all, do: @profiles

  @doc """
  Check if a given value is a valid processing profile.
  """
  @spec valid?(term()) :: boolean()
  def valid?(profile), do: profile in @profiles

  @doc """
  Returns the default timeout in milliseconds for a profile.

  - `:standard` — 15 minutes (900,000 ms)
  - `:enhanced` — 20 minutes (1,200,000 ms)
  """
  @spec default_timeout_ms(t()) :: pos_integer()
  def default_timeout_ms(:standard), do: @standard_timeout_ms
  def default_timeout_ms(:enhanced), do: @enhanced_timeout_ms

  @doc """
  Returns the maximum allowed timeout in milliseconds (hard cap).

  This is 20 minutes (1,200,000 ms) for all profiles.
  """
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms
end
