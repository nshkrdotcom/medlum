defmodule Medlum.Conversion.PolicyTest do
  use Medlum.Conversion.TestCase

  alias Medlum.Conversion.Policy

  describe "validate_file/2" do
    test "returns :ok for valid PDF within size limit" do
      # Create a small binary representing a PDF
      binary = String.duplicate("x", 1024)
      opts = [content_type: "application/pdf"]

      assert Policy.validate_file(binary, opts) == :ok
    end

    test "returns :ok when no content_type specified (defaults to pdf)" do
      binary = String.duplicate("x", 1024)

      assert Policy.validate_file(binary, []) == :ok
    end

    test "returns error for file too large" do
      # Create binary larger than 100MB
      max_size = Policy.max_file_size()
      binary = String.duplicate("x", max_size + 1)
      opts = [content_type: "application/pdf"]

      assert Policy.validate_file(binary, opts) == {:error, :file_too_large}
    end

    test "returns error for file exactly at limit plus one byte" do
      max_size = Policy.max_file_size()
      binary = String.duplicate("x", max_size + 1)

      assert Policy.validate_file(binary, []) == {:error, :file_too_large}
    end

    test "returns :ok for file exactly at limit" do
      max_size = Policy.max_file_size()
      binary = String.duplicate("x", max_size)

      assert Policy.validate_file(binary, []) == :ok
    end

    test "returns error for invalid content type" do
      binary = String.duplicate("x", 1024)
      opts = [content_type: "text/plain"]

      assert Policy.validate_file(binary, opts) == {:error, :invalid_content_type}
    end

    test "returns error for image content type" do
      binary = String.duplicate("x", 1024)
      opts = [content_type: "image/png"]

      assert Policy.validate_file(binary, opts) == {:error, :invalid_content_type}
    end

    test "returns error for word document" do
      binary = String.duplicate("x", 1024)

      opts = [
        content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ]

      assert Policy.validate_file(binary, opts) == {:error, :invalid_content_type}
    end
  end

  describe "user_can_access_profile?/2" do
    test "returns true for :standard profile for any user" do
      user = %{}
      assert Policy.user_can_access_profile?(user, :standard) == true
    end

    test "returns true for :standard profile for nil user" do
      assert Policy.user_can_access_profile?(nil, :standard) == true
    end

    test "returns false for :enhanced profile for basic user" do
      user = %{subscription: :basic}
      assert Policy.user_can_access_profile?(user, :enhanced) == false
    end

    test "returns true for :enhanced profile with premium subscription" do
      user = %{subscription: :premium}
      assert Policy.user_can_access_profile?(user, :enhanced) == true
    end

    test "returns true for :enhanced profile with enhanced_processing feature flag" do
      user = %{feature_flags: %{enhanced_processing: true}}
      assert Policy.user_can_access_profile?(user, :enhanced) == true
    end

    test "returns true for :enhanced profile with cloud_processing_enabled" do
      user = %{cloud_processing_enabled: true}
      assert Policy.user_can_access_profile?(user, :enhanced) == true
    end

    test "returns false for :enhanced when feature flag is false" do
      user = %{feature_flags: %{enhanced_processing: false}}
      assert Policy.user_can_access_profile?(user, :enhanced) == false
    end

    test "returns false for :enhanced when empty user map" do
      user = %{}
      assert Policy.user_can_access_profile?(user, :enhanced) == false
    end
  end

  describe "max_file_size/0" do
    test "returns 100MB in bytes" do
      assert Policy.max_file_size() == 104_857_600
    end
  end

  describe "allowed_content_types/0" do
    test "returns list with application/pdf" do
      types = Policy.allowed_content_types()
      assert is_list(types)
      assert "application/pdf" in types
    end
  end
end
