defmodule MedlumWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MedlumWeb.Markdown

  test "renders Markdown and preserves source citation buttons" do
    html =
      render_component(&Markdown.markdown/1,
        content: "# Summary\n\nSee [doc-101].\n\n| Test |\n| --- |\n| Result |",
        section_id: "summary"
      )

    assert html =~ "<h1>Summary</h1>"
    assert html =~ "<table>"
    assert html =~ ~s(phx-value-doc-id="doc-101")
    assert html =~ ~s(phx-value-section-id="summary")
  end

  test "omits unsafe HTML and link destinations from report Markdown" do
    html =
      render_component(&Markdown.markdown/1,
        content: "<script>alert(1)</script>\n\n[Link](javascript:alert%281%29)"
      )

    refute html =~ "<script>"
    refute html =~ "javascript:"
  end
end
