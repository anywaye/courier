defmodule Courier.OwnerRepo do
  @moduledoc """
  The OWNER credential: `Courier.Repo` is the login that serves, this is the login
  that builds.


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

end
