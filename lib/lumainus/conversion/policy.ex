defmodule Lumainus.Conversion.Policy do
  @moduledoc """
  Validation and authorization policies for conversion jobs.

  ## Responsibilities

  - File validation (size, type)
  - Profile eligibility (feature flags, subscription)
  - Rate limiting hooks (future)

  ## Usage

      # Validate file before submission
      :ok = Policy.validate_file(binary, content_type: "application/pdf")

      # Check profile access
      true = Policy.user_can_access_profile?(user, :enhanced)
  """

  alias Lumainus.Conversion.ProcessingProfile

  # 100 MB maximum file size
  @max_file_size 100 * 1024 * 1024

  # Only PDFs supported for now
  @allowed_content_types ~w(application/pdf)

  @type validation_error ::
          :file_too_large
          | :invalid_content_type
          | :profile_not_available
          | :rate_limited

  @doc """
  Validate file before submission.

  ## Options

  - `:content_type` — MIME type (default: "application/pdf")

  ## Returns

  - `:ok` — File is valid
  - `{:error, :file_too_large}` — File exceeds 100MB
  - `{:error, :invalid_content_type}` — Not a supported file type
  """
  @spec validate_file(binary(), keyword()) :: :ok | {:error, validation_error()}
  def validate_file(binary, opts) when is_binary(binary) do
    content_type = Keyword.get(opts, :content_type, "application/pdf")

    cond do
      byte_size(binary) > @max_file_size ->
        {:error, :file_too_large}

      content_type not in @allowed_content_types ->
        {:error, :invalid_content_type}

      true ->
        :ok
    end
  end

  @doc """
  Check if user can access a profile.

  - `:standard` — Available to all users
  - `:enhanced` — Requires premium subscription or feature flag

  ## User Map Fields (checked in order)

  - `:subscription` — `:premium` grants access
  - `:feature_flags.enhanced_processing` — `true` grants access
  - `:cloud_processing_enabled` — `true` grants access
  """
  @spec user_can_access_profile?(map() | nil, ProcessingProfile.t()) :: boolean()
  def user_can_access_profile?(_user, :standard), do: true

  def user_can_access_profile?(user, :enhanced) when is_map(user) do
    cond do
      Map.get(user, :subscription) == :premium ->
        true

      user |> Map.get(:feature_flags, %{}) |> Map.get(:enhanced_processing) == true ->
        true

      Map.get(user, :cloud_processing_enabled, false) == true ->
        true

      true ->
        false
    end
  end

  def user_can_access_profile?(nil, :enhanced), do: false

  @doc """
  Get maximum file size in bytes (100MB).
  """
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: @max_file_size

  @doc """
  Get list of allowed content types.
  """
  @spec allowed_content_types() :: [String.t()]
  def allowed_content_types, do: @allowed_content_types
end
