defmodule Lumainus.Cldr do
  use Cldr,
    otp_app: :lumainus,
    default_locale: "en",
    locales: ["en", "en-GB", "en-US", "es", "es-US"],
    providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime]
end
