defmodule Lumainus.Reports.BlueprintsTest do
  use ExUnit.Case, async: true

  alias Lumainus.Reports.Blueprints
  alias Lumainus.Reports.SchemaValidator

  describe "section_blueprints/0" do
    test "returns 11 sections" do
      blueprints = Blueprints.section_blueprints()
      assert length(blueprints) == 11
    end

    test "all sections have required keys" do
      for blueprint <- Blueprints.section_blueprints() do
        assert Map.has_key?(blueprint, :identifier)
        assert Map.has_key?(blueprint, :title)
        assert Map.has_key?(blueprint, :focus)
        assert Map.has_key?(blueprint, :instructions)
      end
    end

    test "section identifiers are unique kebab-case strings" do
      identifiers = Enum.map(Blueprints.section_blueprints(), & &1.identifier)

      # All unique
      assert length(identifiers) == length(Enum.uniq(identifiers))

      # All kebab-case
      for identifier <- identifiers do
        assert identifier =~ ~r/^[a-z]+(-[a-z]+)*$/,
               "Expected #{identifier} to be kebab-case"
      end
    end

    test "includes expected sections" do
      identifiers = Blueprints.section_identifiers()

      expected = [
        "chief-complaint",
        "history-present-illness",
        "past-history",
        "medications",
        "physical-exam-history",
        "review-of-systems",
        "lab-review",
        "imaging-review",
        "pathology-review",
        "assessment",
        "plan"
      ]

      assert identifiers == expected
    end
  end

  describe "section_identifiers/0" do
    test "returns list of identifiers" do
      identifiers = Blueprints.section_identifiers()
      assert is_list(identifiers)
      assert length(identifiers) == 11
      assert hd(identifiers) == "chief-complaint"
    end
  end

  describe "default_output_schema/0" do
    test "returns valid JSON Schema" do
      schema = Blueprints.default_output_schema()

      assert schema["type"] == "object"
      assert Map.has_key?(schema, "properties")
      assert Map.has_key?(schema, "required")
    end

    test "schema validates with SchemaValidator" do
      schema = Blueprints.default_output_schema()
      assert SchemaValidator.valid?(schema)
    end

    test "has expected properties" do
      schema = Blueprints.default_output_schema()
      properties = schema["properties"]

      assert Map.has_key?(properties, "title")
      assert Map.has_key?(properties, "summary")
      assert Map.has_key?(properties, "markdown")
      assert Map.has_key?(properties, "citations")
    end

    test "citations array has items schema" do
      schema = Blueprints.default_output_schema()
      citations = schema["properties"]["citations"]

      assert citations["type"] == "array"
      assert Map.has_key?(citations, "items")
    end
  end

  describe "citations_item_schema/0" do
    test "returns object schema for citations" do
      schema = Blueprints.citations_item_schema()

      assert schema["type"] == "object"
      assert Map.has_key?(schema["properties"], "label")
      assert Map.has_key?(schema["properties"], "document_id")
      assert Map.has_key?(schema["properties"], "line_start")
    end
  end

  describe "default_ingestion_prompt/0" do
    test "returns non-empty string" do
      prompt = Blueprints.default_ingestion_prompt()

      assert is_binary(prompt)
      assert String.length(prompt) > 100
    end

    test "contains key instructions" do
      prompt = Blueprints.default_ingestion_prompt()

      assert prompt =~ "markdown"
      assert prompt =~ "summary"
    end
  end

  describe "default_template_attrs/0" do
    test "returns map with required keys" do
      attrs = Blueprints.default_template_attrs()

      assert Map.has_key?(attrs, :name)
      assert Map.has_key?(attrs, :slug)
      assert Map.has_key?(attrs, :description)
    end

    test "slug is valid format" do
      attrs = Blueprints.default_template_attrs()

      assert attrs.slug =~ ~r/^[a-z]+(-[a-z]+)*$/
    end
  end

  describe "default_system_prompt/0" do
    test "returns non-empty string" do
      prompt = Blueprints.default_system_prompt()

      assert is_binary(prompt)
      assert String.length(prompt) > 50
    end

    test "includes Lumainus identity" do
      prompt = Blueprints.default_system_prompt()

      assert prompt =~ "Lumainus"
    end

    test "includes JSON requirement" do
      prompt = Blueprints.default_system_prompt()

      assert prompt =~ "JSON"
    end
  end

  describe "section_prompt/2" do
    test "generates prompt with focus" do
      prompt = Blueprints.section_prompt("the patient's symptoms")

      assert prompt =~ "the patient's symptoms"
    end

    test "includes template variables" do
      prompt = Blueprints.section_prompt("test focus")

      assert prompt =~ "<%= section_title %>"
      assert prompt =~ "<%= patient"
      assert prompt =~ "<%= documents"
    end

    test "includes instructions when provided" do
      prompt =
        Blueprints.section_prompt("test focus",
          instructions: "- Use bullet points\n- Be concise"
        )

      assert prompt =~ "Use bullet points"
      assert prompt =~ "Be concise"
      assert prompt =~ "Clinical formatting guidance"
    end

    test "omits instructions block when not provided" do
      prompt = Blueprints.section_prompt("test focus")

      refute prompt =~ "Clinical formatting guidance"
    end

    test "includes citation instructions" do
      prompt = Blueprints.section_prompt("test focus")

      assert prompt =~ "citation"
      assert prompt =~ "document_id"
    end
  end
end
