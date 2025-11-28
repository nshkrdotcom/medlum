defmodule LumainusWeb.DateTimeHelpersTest do
  use ExUnit.Case, async: true

  alias Lumainus.Cldr.DateTime, as: CldrDateTime
  alias Lumainus.Cldr.DateTime.Relative, as: CldrDateTimeRelative
  alias LumainusWeb.DateTimeHelpers

  test "formats datetime using locale and time zone" do
    utc_dt = ~U[2025-01-15 12:00:00Z]
    shifted = DateTime.shift_zone!(utc_dt, "America/New_York")

    expected = CldrDateTime.to_string!(shifted, format: :medium, locale: "en")

    assert DateTimeHelpers.format_datetime(utc_dt,
             locale: "en",
             timezone: "America/New_York",
             format: :medium
           ) == expected
  end

  test "formats relative time against a reference" do
    base = ~U[2025-01-15 12:00:00Z]
    later = ~U[2025-01-15 13:00:00Z]

    expected =
      CldrDateTimeRelative.to_string!(
        DateTime.shift_zone!(later, "Etc/UTC"),
        relative_to: DateTime.shift_zone!(base, "Etc/UTC"),
        locale: "en"
      )

    assert DateTimeHelpers.format_relative(later,
             locale: "en",
             timezone: "Etc/UTC",
             relative_to: base
           ) == expected
  end

  test "falls back gracefully on invalid input" do
    assert DateTimeHelpers.format_datetime("not-a-date", locale: "en", timezone: "Etc/UTC") == nil
  end
end
