defmodule Courier.OwnerRepo do
  @moduledoc """
  The OWNER credential: `Courier.Repo` is the login that serves, this is the login
  that builds.

  ## WHY THERE ARE TWO REPOS AND NOT ONE CONFIG WITH A SWITCH

  kit's cluster provisions two roles per service
  (`kit/templates/compose/postgres/initdb/10-cluster.sh`):

    * `<service>`      — the OWNER. LOGIN, owns the database and every table, runs
      the migrations. **Not** a superuser.
    * `<service>_app`  — the LOGIN the application uses. Owns nothing, holds DML per
      table and nothing else: no ownership, no DDL, no ability to alter a policy.

  `Courier.Repo` connects as `courier_app`. `courier_app` cannot `CREATE DATABASE`
  and cannot `CREATE TABLE`, so `mix ecto.create` and `mix ecto.migrate` cannot run
  as it — the outcome is a two-credential arrangement and **the arrangement is
  structural rather than a switch**, because that is the only shape in which the
  test run cannot silently acquire the owner's privileges.

  The version that was measured and rejected: one repo whose config is overwritten
  by an environment variable when the caller is a bootstrap task.

      COURIER_OWNER_DATABASE_URL=ecto://courier:…@… mix test

  There is exactly ONE repo key, so that line does not "make migrations run as the
  owner" — it makes **the whole run, tests included, run as the owner**, and the
  suite goes green with the account boundary switched off, which is the failure this
  packet exists to end. Nothing in the shape distinguishes the two phases; a
  developer who sets the variable once has a green suite that proves nothing. Two
  modules make the phase a compile-time fact: the owner is reachable from
  `mix.exs`'s aliases and from `Courier.Release`, and the application never names
  it.

  ## NOT IN THE SUPERVISION TREE, ON PURPOSE

  `:ecto_repos` is `[Courier.Repo]` and this module is not in it, so
  `mix ecto.create -r Courier.OwnerRepo` starts it for the task and it stops with
  the task. Nothing in a running release opens a connection as the owner, which is
  the entire point: an owner connection that outlives the migration is a role that
  bypasses every policy in
  `priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs`.

  `otp_app` is `:courier`, so `priv/repo/migrations` and `priv/repo/seeds.exs`
  resolve to the same paths this repo's own repo uses. Two repos, one migrations
  directory, one `schema_migrations` table — they are the same database.
  """

  use Ecto.Repo,
    otp_app: :courier,
    adapter: Ecto.Adapters.Postgres

  # `priv/repo/migrations` is named in `config/dev.exs` and `config/test.exs` as
  # `priv: "priv/repo"`, and it has to be: Ecto derives a repo's migrations
  # directory from its module name — `Courier.OwnerRepo` reaches for
  # `priv/owner_repo/migrations`, finds nothing, CREATES the empty directory, and
  # reports a migration source that is silently empty:
  #
  #     ** (Mix) Could not find migrations directory "priv/owner_repo/migrations"
  #
  # **`use Ecto.Repo, priv: …` does not fix it.** Measured: `config/0` is
  # `Ecto.Repo.Supervisor.init_config(:runtime, module, otp_app, [])`, and
  # `init_config/4` reads `Application.get_env(otp_app, repo, [])` — the `opts`
  # `use` was given reach `compile_config/2`, which looks for `:otp_app` and
  # `:adapter` and ignores everything else. So the key has to be in the
  # environment, and it is in both files that configure this repo.
  #
  # Two repos, one schema, one set of migrations, one `schema_migrations` table.
end
