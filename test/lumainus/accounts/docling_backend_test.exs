defmodule Lumainus.Accounts.DoclingBackendTest do
  use Lumainus.DataCase, async: true

  @moduletag :capture_log

  alias Lumainus.Accounts
  alias Lumainus.AccountsFixtures

  test "docling backend defaults to local" do
    user = AccountsFixtures.user_fixture()

    assert Accounts.docling_backend_for_user(user) == :local
  end

  test "update_docling_backend persists selection" do
    user = AccountsFixtures.user_fixture()

    # :fast is an alias for :cloud in v2
    assert {:ok, updated} = Accounts.update_docling_backend(user, :fast)
    assert updated.docling_backend == "cloud"
    assert Accounts.docling_backend_for_user(updated) == :cloud
  end
end
