defmodule Courier.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  ## WHY MIGRATIONS RUN AS THE OWNER AND NOT AS `:ecto_repos`

  `migrate/0` used to iterate `Application.fetch_env!(:courier, :ecto_repos)`,
  which is `[Courier.Repo]` — and `Courier.Repo` connects as **`courier_app`**,
  the app login role that owns nothing (see `config/runtime.exs` and
  `Courier.OwnerRepo`).

  A migration is DDL, and `courier_app` is `NOCREATEDB` and holds no privilege on
  any table it does not write. So a release that ran migrations through
  `:ecto_repos` would fail on the **first** migration that creates a table, with
  `permission denied for schema public` — from a binary whose application half
  works fine, which is the worst place for the failure to live.

  So the repo list is `[Courier.OwnerRepo]`, named rather than derived. The two
  are the same database and the same `priv/repo/migrations`; they differ only in
  the credential, and picking the credential is exactly what this function is for.

  ## IT FAILS BY NAME WHEN THE OWNER IS NOT CONFIGURED

  `config/runtime.exs` only configures `Courier.OwnerRepo` when
  `COURIER_OWNER_DATABASE_URL` is set, and it does **not** require it at boot: the
  running application never needs it, and refusing to start over a migration
  credential would take a healthy release down for something no request reads.

  So the refusal lands here, where it costs one deploy step rather than a
  service:

      could not find Ecto repo config for Courier.OwnerRepo under :courier

  That message comes from Ecto rather than from a hand-written `raise`, and it is
  the right one to surface: it names the module and the application key, which is
  what somebody debugging a failed `bin/migrate` needs.
  """
  @app :courier

  @doc """
  Runs every pending migration, as the OWNER.

  Not `Courier.Repo` and not `:ecto_repos` — see the moduledoc for the measured
  reason.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls `repo` back to `version`.

  `repo` is named by the caller, and the caller is a human with a reason — the
  name is left as an argument rather than forced to the owner, because
  `Ecto.Migrator.run/3` against a repo that was never configured is a legible
  failure and guessing a different repo would not be.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    [Courier.OwnerRepo]
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
