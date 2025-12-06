defmodule Lumainus.ExternalApi.Log do
  @moduledoc """
  Append-only log of external API calls (Vast.ai, Cloudflare).

  Used for debugging, auditing, and understanding API usage patterns.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "external_api_logs" do
    field(:service, :string)
    field(:method, :string)
    field(:path, :string)
    field(:status, :integer)
    field(:latency_ms, :integer)
    field(:error, :string)

    timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec)
  end
end
