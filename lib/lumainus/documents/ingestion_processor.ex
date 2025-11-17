defmodule Lumainus.Documents.IngestionProcessor do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.AI
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Documents.{DocumentChunk, DocumentParse, DocumentUpload, IngestionJob}
  alias Lumainus.Clinical.PatientProfile
  alias Lumainus.Repo
  alias Lumainus.Reports
  alias ReqLLM.Context
  alias __MODULE__.PdfExtractor
  alias Path

  def process(job_id) do
    job =
      IngestionJob
      |> Repo.get!(job_id)
      |> Repo.preload(upload: [patient: [:current_profile]])

    Repo.transaction(fn ->
      job
      |> Changeset.change(%{status: "processing", started_at: DateTime.utc_now(:second)})
      |> Repo.update!()
    end)

    result =
      with {:ok, template} <- fetch_template(job),
           {:ok, text} <- extract_pdf(job.upload),
           {:ok, response} <- run_llm(job, template, text),
           {:ok, _parse} <- persist_parse(job.upload, response) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    finalize_job(job, result)
  end

  defp fetch_template(%IngestionJob{metadata: %{"template_id" => template_id}}) do
    template = Reports.get_template!(template_id)
    {:ok, template}
  rescue
    _ -> {:error, :template_missing}
  end

  defp fetch_template(_job), do: {:error, :template_missing}

  defp extract_pdf(%DocumentUpload{} = upload) do
    PdfExtractor.from_binary(upload.raw_blob, upload.filename)
  end

  defp run_llm(job, template, text) do
    prompt = Reports.ingestion_prompt(template)

    user_content = """
    Filename: #{job.upload.filename}
    Size: #{job.upload.byte_size} bytes

    Raw text:
    #{text}
    """

    messages =
      Context.new([
        Context.system(prompt),
        Context.user(user_content)
      ])

    model_spec = AI.model_spec()
    options = AI.options()
    schema = ingestion_schema()

    llm =
      %LlmInvocation{}
      |> LlmInvocation.changeset(%{
        tenant_id: job.tenant_id,
        provider: "google",
        model: "gemini-flash-lite-latest",
        prompt_text: prompt,
        prompt_context: %{"filename" => job.upload.filename, "document_id" => job.upload.id},
        status: "pending",
        temperature: Keyword.get(options, :temperature),
        max_output_tokens: Keyword.get(options, :max_output_tokens)
      })
      |> Repo.insert!()

    started = System.monotonic_time()

    case AI.client().generate_object(model_spec, messages, schema, options) do
      {:ok, response} ->
        duration = duration_ms(started)

        Repo.update!(
          Changeset.change(llm, %{
            response_text: response |> Map.get(:text),
            response_object: stringify(response),
            usage: Map.get(response, :usage, %{}),
            status: "completed",
            req_duration_ms: duration
          })
        )

        {:ok, stringify(response)}

      {:error, reason} ->
        Repo.update!(
          Changeset.change(llm, %{
            status: "error",
            error: %{message: inspect(reason)}
          })
        )

        {:error, reason}
    end
  end

  defp persist_parse(upload, response) do
    markdown =
      get_in(response, ["object", "markdown"]) || get_in(response, ["markdown"]) || "No content"

    summary =
      get_in(response, ["object", "summary"]) || get_in(response, ["summary"]) ||
        "Summary unavailable"

    provider = get_in(response, ["object", "source_provider"])
    label = upload.metadata["label"] || Path.rootname(upload.filename)

    parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "llm-ingestion",
        parsed_text: markdown,
        structured_metadata: response,
        extracted_at: DateTime.utc_now(:second),
        patient_profile_id: upload.patient && upload.patient.current_profile_id
      })
      |> Repo.insert!()

    %DocumentChunk{}
    |> DocumentChunk.changeset(%{
      parse_id: parse.id,
      position: 0,
      content: markdown,
      token_count: length(String.split(markdown))
    })
    |> Repo.insert!()

    maybe_update_patient(upload, response)

    metadata =
      upload.metadata
      |> Map.put("summary", summary)
      |> Map.put("provider", provider || upload.metadata["provider"])
      |> Map.put("label", label)
      |> Map.put("status", "parsed")

    upload
    |> Changeset.change(%{
      status: "parsed",
      metadata: metadata,
      ingested_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()

    {:ok, parse}
  end

  defp maybe_update_patient(%DocumentUpload{patient: nil}, _response), do: :ok

  defp maybe_update_patient(%DocumentUpload{patient: patient}, response) do
    profile = patient.current_profile && Repo.preload(patient, :current_profile).current_profile

    if profile do
      patient_name =
        get_in(response, ["object", "patient_name"]) || get_in(response, ["patient_name"])

      {first_name, last_name} = split_name(patient_name)

      attrs =
        %{
          given_name: first_name,
          family_name: last_name,
          mrn: get_in(response, ["object", "patient_mrn"]) || get_in(response, ["patient_mrn"]),
          structured_metadata:
            Map.merge(profile.structured_metadata || %{}, %{"ingestion" => response})
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) || v == "" end)
        |> Enum.into(%{})

      if map_size(attrs) > 0 do
        profile
        |> PatientProfile.changeset(attrs)
        |> Repo.update()
      else
        :ok
      end
    else
      :ok
    end
  end

  defp finalize_job(job, :ok) do
    job
    |> Changeset.change(%{status: "completed", finished_at: DateTime.utc_now(:second)})
    |> Repo.update!()
  end

  defp finalize_job(job, {:error, reason}) do
    job
    |> Changeset.change(%{
      status: "failed",
      finished_at: DateTime.utc_now(:second),
      error: %{message: inspect(reason)}
    })
    |> Repo.update!()
  end

  defp ingestion_schema do
    %{
      "fields" => [
        %{"name" => "markdown", "type" => "string", "required" => true},
        %{"name" => "summary", "type" => "string", "required" => true},
        %{"name" => "patient_name", "type" => "string", "required" => false},
        %{"name" => "patient_mrn", "type" => "string", "required" => false},
        %{"name" => "source_provider", "type" => "string", "required" => false}
      ]
    }
  end

  defp duration_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end

  defp stringify(%{object: obj} = response) when is_map(obj) do
    Map.update!(response, :object, &stringify_keys/1)
  end

  defp stringify(map) when is_map(map) do
    stringify_keys(map)
  end

  defp stringify(other), do: other

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {k, v} ->
      value = if is_map(v), do: stringify_keys(v), else: v
      {to_string(k), value}
    end)
    |> Enum.into(%{})
  end

  defp split_name(nil), do: {nil, nil}

  defp split_name(name) do
    case String.split(name, " ", trim: true) do
      [] -> {nil, nil}
      [single] -> {single, nil}
      parts -> {List.first(parts), List.last(parts)}
    end
  end

  defmodule PdfExtractor do
    def from_binary(binary, filename) do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lumainus_pdf_#{System.unique_integer([:positive])}#{Path.extname(filename)}"
        )

      File.write!(tmp, binary)

      result =
        case System.cmd("pdftotext", [tmp, "-"]) do
          {text, 0} when byte_size(text) > 0 -> {:ok, text}
          _ -> {:ok, IO.iodata_to_binary(binary)}
        end

      File.rm(tmp)
      result
    rescue
      _ -> {:ok, IO.iodata_to_binary(binary)}
    end
  end
end
