defmodule Medlum.Conversion.ProcessingProfileTest do
  use Medlum.Conversion.TestCase

  alias Medlum.Conversion.ProcessingProfile

  describe "all/0" do
    test "returns list of available profiles" do
      profiles = ProcessingProfile.all()
      assert is_list(profiles)
      assert :standard in profiles
      assert :enhanced in profiles
      assert length(profiles) == 2
    end
  end

  describe "valid?/1" do
    test "returns true for :standard" do
      assert ProcessingProfile.valid?(:standard) == true
    end

    test "returns true for :enhanced" do
      assert ProcessingProfile.valid?(:enhanced) == true
    end

    test "returns false for invalid profile atoms" do
      assert ProcessingProfile.valid?(:invalid) == false
      assert ProcessingProfile.valid?(:premium) == false
      assert ProcessingProfile.valid?(:basic) == false
    end

    test "returns false for non-atom values" do
      assert ProcessingProfile.valid?("standard") == false
      assert ProcessingProfile.valid?(nil) == false
      assert ProcessingProfile.valid?(123) == false
    end
  end

  describe "default_timeout_ms/1" do
    test "returns 15 minutes (900_000 ms) for :standard" do
      assert ProcessingProfile.default_timeout_ms(:standard) == 900_000
    end

    test "returns 20 minutes (1_200_000 ms) for :enhanced" do
      assert ProcessingProfile.default_timeout_ms(:enhanced) == 1_200_000
    end
  end

  describe "max_timeout_ms/0" do
    test "returns 20 minutes (1_200_000 ms) as absolute cap" do
      assert ProcessingProfile.max_timeout_ms() == 1_200_000
    end
  end
end
