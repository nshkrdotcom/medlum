defmodule Lumainus.Reports.SchemaValidatorTest do
  use ExUnit.Case, async: true

  alias Lumainus.Reports.SchemaValidator

  describe "validate/1" do
    test "accepts valid object schema with properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        }
      }

      assert {:ok, ^schema} = SchemaValidator.validate(schema)
    end

    test "rejects non-object root type" do
      schema = %{"type" => "string"}

      assert {:error, "Root type must be 'object', got 'string'"} =
               SchemaValidator.validate(schema)
    end

    test "rejects missing type at root" do
      schema = %{"properties" => %{}}
      assert {:error, "Root type must be 'object'"} = SchemaValidator.validate(schema)
    end

    test "rejects nil schema" do
      assert {:error, "Schema must be a JSON object"} = SchemaValidator.validate(nil)
    end

    test "rejects non-map schema" do
      assert {:error, "Schema must be a JSON object"} = SchemaValidator.validate("not a map")
    end

    test "rejects missing properties object" do
      schema = %{"type" => "object"}
      assert {:error, "Missing 'properties' object"} = SchemaValidator.validate(schema)
    end

    test "rejects invalid property types" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "foo" => %{"type" => "invalid_type"}
        }
      }

      assert {:error, "Property 'foo' has invalid type 'invalid_type'"} =
               SchemaValidator.validate(schema)
    end

    test "rejects property without type" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "foo" => %{"description" => "missing type"}
        }
      }

      assert {:error, "Property 'foo' missing 'type'"} = SchemaValidator.validate(schema)
    end

    test "accepts all valid types" do
      for type <- ["string", "number", "integer", "boolean", "object", "array"] do
        schema =
          if type == "array" do
            %{
              "type" => "object",
              "properties" => %{"field" => %{"type" => type, "items" => %{"type" => "string"}}}
            }
          else
            %{"type" => "object", "properties" => %{"field" => %{"type" => type}}}
          end

        assert {:ok, _} = SchemaValidator.validate(schema),
               "Expected #{type} to be valid"
      end
    end
  end

  describe "array validation" do
    test "rejects array without items" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "tags" => %{"type" => "array"}
        }
      }

      assert {:error, "Array property 'tags' must have 'items' definition"} =
               SchemaValidator.validate(schema)
    end

    test "accepts array with items" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          }
        }
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end

    test "rejects nested array without items" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "outer" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "inner" => %{"type" => "array"}
              }
            }
          }
        }
      }

      assert {:error, _msg} = SchemaValidator.validate(schema)
    end

    test "accepts array with object items" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "citations" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "label" => %{"type" => "string"},
                "line" => %{"type" => "integer"}
              }
            }
          }
        }
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end
  end

  describe "required fields validation" do
    test "accepts when required fields exist in properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end

    test "rejects when required fields not in properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name", "missing_field"]
      }

      assert {:error, msg} = SchemaValidator.validate(schema)
      assert msg =~ "Required fields not in properties"
      assert msg =~ "missing_field"
    end

    test "accepts schema without required array" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        }
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end
  end

  describe "nested object validation" do
    test "validates nested object properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{
              "street" => %{"type" => "string"},
              "city" => %{"type" => "string"}
            }
          }
        }
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end

    test "rejects invalid type in nested object" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{
              "street" => %{"type" => "invalid"}
            }
          }
        }
      }

      assert {:error, msg} = SchemaValidator.validate(schema)
      assert msg =~ "invalid type"
    end
  end

  describe "valid?/1" do
    test "returns true for valid schema" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert SchemaValidator.valid?(schema)
    end

    test "returns false for invalid schema" do
      schema = %{"type" => "string"}
      refute SchemaValidator.valid?(schema)
    end
  end

  describe "validate_json/1" do
    test "validates and parses valid JSON" do
      json = ~s({"type": "object", "properties": {"name": {"type": "string"}}})

      assert {:ok, schema} = SchemaValidator.validate_json(json)
      assert schema["type"] == "object"
    end

    test "returns error for invalid JSON syntax" do
      json = "not valid json"
      assert {:error, "Invalid JSON syntax"} = SchemaValidator.validate_json(json)
    end

    test "returns error for valid JSON but invalid schema" do
      json = ~s({"type": "string"})
      assert {:error, _msg} = SchemaValidator.validate_json(json)
    end
  end

  describe "real-world schema - Gemini output" do
    test "validates the default output schema structure" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "summary" => %{"type" => "string"},
          "markdown" => %{"type" => "string"},
          "citations" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "label" => %{"type" => "string"},
                "document_id" => %{"type" => "string"},
                "document_reference" => %{"type" => "string"},
                "line_start" => %{"type" => "integer"},
                "line_end" => %{"type" => "integer"},
                "excerpt" => %{"type" => "string"}
              }
            },
            "description" => "List of citations with label and document_id"
          }
        },
        "required" => ["title", "summary", "markdown", "citations"]
      }

      assert {:ok, _} = SchemaValidator.validate(schema)
    end
  end
end
