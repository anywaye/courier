defmodule CourierWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CourierWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.

  ## WHY THIS CALLS `Courier.DataCase.setup_sandbox/1` AND NOT ITS OWN

  It always has, and that was already the reason the sandbox was shared: one
  implementation of "a test runs in a transaction" is one thing to change. This
  packet makes that more load-bearing rather than less, because
  `setup_sandbox/1` is now also where a file's `@moduletag account:` becomes the
  identity Postgres sees. A second `setup_sandbox` here would be a second place
  that either sets the identity or quietly does not, and only one of them failing
  would leave a controller test writing protected rows with no identity — a `42501`
  naming a table rather than a harness.

  So a file that seeds `webhook_endpoints` through a controller test declares
  `@moduletag account: @account_id` exactly as a `Courier.DataCase` file does.
  The account is not read from the request: each controller action opens its
  own `Courier.Tenancy.with_account/3` transaction around its database work,
  and the tag is for the **seeding**, which happens outside any request.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CourierWeb.Endpoint

      use CourierWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CourierWeb.ConnCase

      # `Ecto.Query`, because a `ConnCase` file that asserts about rows needs
      # `from/2` and this import is the only thing that brings the macro in.
      # Calling `Ecto.Query.from/2` qualified instead FAILS, and the message is
      # easy to miss in a long compile log:
      #
      #     function Ecto.Query.from/2 is undefined or private. However, there
      #     is a macro with the same name and arity.
      #
      # followed by four `misplaced operator ^account_id` errors, because the pin
      # is supported only inside a macro. `Courier.DataCase` already imports it,
      # which is why the same query compiles in one harness and not the other.
      import Ecto.Query

      # `Courier.DataCase`, for `as_account/2` — the helper that runs a seeding
      # step under a different account identity and puts the file's own back.
      # `setup_sandbox/1` is already called from this harness's `setup`, so the
      # module was a dependency of every ConnCase file whether it imported it or
      # not; importing it makes the *other* half reachable too.
      import Courier.DataCase
    end
  end

  setup tags do
    Courier.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
