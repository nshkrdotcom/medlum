defmodule Lumainus.AI.SectionRunnerTest do
  use Lumainus.DataCase

  @moduletag :capture_log

  import Lumainus.AccountsFixtures

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Documents
  alias Lumainus.Reports
  alias Lumainus.Reports.{ReportRun, ReportSectionRun}
  alias Lumainus.Repo

  setup do
    user = user_fixture()
    {:ok, user} = Repo.update(Changeset.change(user, role: "doctor"))
    scope = Scope.for_user(user)

    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    Documents.seed_sample_documents(scope, workspace.patient, workspace.record_set,
      include_local: false
    )

    fresh_workspace = Reports.workspace(scope)
    documents = Reports.list_documents(scope, fresh_workspace.record_set)
    patient = Repo.preload(fresh_workspace.patient, :current_profile)
    section_template = hd(fresh_workspace.template.sections)

    run =
      %ReportRun{}
      |> ReportRun.changeset(%{
        tenant_id: scope.tenant_id,
        patient_id: patient.id,
        record_set_id: fresh_workspace.record_set.id,
        template_id: fresh_workspace.template.id,
        run_type: "section",
        status: "queued"
      })
      |> Repo.insert!()

    section_run =
      %ReportSectionRun{}
      |> ReportSectionRun.changeset(%{
        report_run_id: run.id,
        section_template_id: section_template.id,
        status: "queued"
      })
      |> Repo.insert!()

    {:ok, scope: scope, patient: patient, documents: documents, section_run: section_run}
  end

  test "persists markdown output and citations", %{
    scope: scope,
    patient: patient,
    documents: documents,
    section_run: section_run
  } do
    {:ok, _run} = SectionRunner.run_section(scope, section_run, patient, documents)

    reloaded =
      ReportSectionRun
      |> Repo.get!(section_run.id)
      |> Repo.preload(:citations)

    assert reloaded.status == "completed"
    assert reloaded.output_markdown =~ "Mock Section Output"
    assert length(reloaded.citations) == 1
    assert hd(reloaded.citations).document_id
  end

  test "marks section as error when client fails", %{
    scope: scope,
    patient: patient,
    documents: documents,
    section_run: section_run
  } do
    with_llm_client(Lumainus.AI.SectionRunnerTest.FailingClient, fn ->
      {:error, _run} = SectionRunner.run_section(scope, section_run, patient, documents)

      reloaded = Repo.get!(ReportSectionRun, section_run.id)
      assert reloaded.status == "error"
      assert reloaded.error["message"] =~ "failing"
    end)
  end

  test "passes normalized schema to the LLM client", %{
    scope: scope,
    patient: patient,
    documents: documents,
    section_run: section_run
  } do
    with_llm_client(Lumainus.AI.SectionRunnerTest.SchemaCaptureClient, fn ->
      {:ok, _run} = SectionRunner.run_section(scope, section_run, patient, documents)

      assert_receive {:schema_payload, schema}
      assert schema["type"] == "object"
      assert Map.has_key?(schema["properties"], "citations")
    end)
  end

  defmodule FailingClient do
    @behaviour Lumainus.LLM.Client

    @impl true
    def generate_object(_model_spec, _prompt_text, _schema, _opts \\ []) do
      {:error, %RuntimeError{message: "failing client"}}
    end
  end

  defmodule SchemaCaptureClient do
    @behaviour Lumainus.LLM.Client

    @impl true
    def generate_object(_model_spec, _prompt_text, schema, _opts \\ []) do
      send(self(), {:schema_payload, schema})

      {:ok,
       %{
         "object" => %{
           "markdown" => "## Captured",
           "citations" => []
         },
         "text" => "## Captured",
         "usage" => %{}
       }}
    end
  end

  defp with_llm_client(client, fun) do
    original = Application.get_env(:lumainus, :llm, [])
    updated = Keyword.put(original, :client, client)

    try do
      Application.put_env(:lumainus, :llm, updated)
      fun.()
    after
      Application.put_env(:lumainus, :llm, original)
    end
  end

  describe "schema_to_json/1" do
    test "normalizes keyword schemas with list items" do
      keyword_schema = [
        title: [type: :string, required: true],
        summary: [type: :string, required: true],
        markdown: [type: :string, required: true],
        citations: [
          type: :list,
          required: true,
          items: [
            type: :map,
            fields: [
              label: [type: :string, required: true],
              document_id: [type: :string, required: true],
              document_reference: [type: :string],
              line_start: [type: :integer],
              line_end: [type: :integer]
            ]
          ]
        ]
      ]

      json = SectionRunner.schema_to_json(keyword_schema)

      assert json["type"] == "object"
      assert Enum.sort(json["required"]) == ~w[citations markdown summary title]

      citations = json["properties"]["citations"]
      assert citations["type"] == "array"

      item_schema = citations["items"]
      assert item_schema["type"] == "object"
      assert item_schema["properties"]["label"]["type"] == "string"
      assert Enum.member?(item_schema["required"], "label")
    end

    test "deals with maps containing nested fields maps" do
      stored_schema = %{
        "fields" => %{
          "type" => "object",
          "fields" => [
            %{"name" => "title", "type" => "string", "required" => true},
            %{"name" => "summary", "type" => "string", "required" => true},
            %{
              "name" => "citations",
              "type" => "list",
              "required" => true,
              "items" => %{
                "fields" => [
                  %{"name" => "label", "type" => "string", "required" => true},
                  %{"name" => "document_reference", "type" => "string"}
                ],
                "type" => "map"
              }
            }
          ]
        }
      }

      json = SectionRunner.schema_to_json(stored_schema)
      assert json["type"] == "object"
      assert json["properties"]["title"]["type"] == "string"
      assert json["properties"]["citations"]["type"] == "array"
    end
  end

  describe "schema_for_llm/1" do
    test "converts stored schemas into JSON maps" do
      stored_schema = %{
        "type" => "object",
        "required" => ["title", "citations"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "citations" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["label"],
              "properties" => %{
                "label" => %{"type" => "string"},
                "document_reference" => %{"type" => "string"}
              }
            }
          }
        }
      }

      schema = SectionRunner.schema_for_llm(stored_schema)

      assert schema["type"] == "object"
      assert schema["properties"]["title"]["type"] == "string"
      assert schema["properties"]["citations"]["type"] == "array"
    end

    test "returns nil when schema missing" do
      assert SectionRunner.schema_for_llm(nil) == nil
    end
  end
end
