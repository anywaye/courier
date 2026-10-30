defmodule Courier.BackupConfigTest do
  @moduledoc """
  courier's backup configuration is a real configuration, and it is reachable.


  `config/kamal-backup.yml` is not read by courier. Nothing in this repository
  opens it. It is mounted, read-only, into the `backup` accessory's container by
  one line in `config/deploy.yml`:

      - config/kamal-backup.yml:/app/config/kamal-backup.yml:ro

  Delete that line and the file is still there, still valid YAML, still a careful
  description of what to back up — and nothing runs it. That is the same defect
  one layer down as a backup config that does not exist, and it is invisible to
  every check that reads one file. So this test reads **both** files and asserts
  the connection, which is also the only way to see the second half of the
  problem below.


  `kamal-backup validate` builds the accessory's environment from
  `config/deploy.yml` and from nothing else — not from the process, not from
  `.kamal/secrets`, not from the backup config. So a secret named in
  `config/kamal-backup.yml` and absent from the backup accessory's `env.secret`
  list is a valid file in each, internally consistent in each, and **rejected by
  the pair**, with `RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required`
  (measured on kamal-backup 0.5.2, which is the version the accessory image is
  pinned to).

  That failure was verified rather than asserted here: the real binaries accept
  the pair this repository now ships, and reject it when one secret is deleted
  from the accessory's list. What this suite does is hold the same contract in
  the gate, where it runs on every commit and needs no Ruby.


  Three claims here are "this is NOT in the file": no key material, no file
  paths, no `COURIER_SECRET_BOX_KEY`. Each is paired with an assertion that the
  thing it protects is present, because a boundary that deletes everything passes
  every "deletes nothing" test — the same three bugs that left
  `Courier.TelemetryCanaryTest` green with nothing exported at all
  (`AGENTS.md`). So this file also asserts that the secrets it forbids are
  replaceable by real ones, that the mount exists, and that the schedule is the
  one README quotes.


  `use ExUnit.Case`, not `Courier.DataCase`. Both files are read from disk and
  nothing here touches `Courier.Repo`, so this belongs to the no-database tier —
  and a backup configuration that could only be checked against a running
  postgres would be one a CI runner without a database silently skips.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.KamalConfig

  @backup_path "config/kamal-backup.yml"
  @deploy_path "config/deploy.yml"
  @readme "README.md"

  @permitted_secrets ~w(
    DATABASE_URL
    DATABASE_PASSWORD
    RESTIC_REPOSITORY
    RESTIC_PASSWORD
  )

  @accessory_only_secrets ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)

  setup_all do
    {:ok, backup: KamalConfig.backup!(@backup_path), deploy: KamalConfig.deploy!(@deploy_path)}
  end

  describe "reachability" do
    test "the backup accessory mounts config/kamal-backup.yml into the container that reads it",
         %{
           backup: _backup,
           deploy: deploy
         } do
      assert KamalConfig.mounts_backup_config?(deploy),
             "#{@deploy_path} mounts #{inspect(deploy.mounts)}, and none of them puts " <>
               "#{@backup_path} at /app/config/kamal-backup.yml. Nothing reads that file except the " <>
               "accessory it is mounted into, so without this line courier has no backup configuration " <>
               "— it has a file."
    end

    test "the accessory the backup config names is one the deploy config declares", %{
      backup: backup,
      deploy: deploy
    } do
      assert backup.accessory,
             "#{@backup_path} names no `accessory:`. That name is how kamal-backup finds the container " <>
               "to run in and that container's secrets, so without it there is nothing to resolve."

      assert backup.accessory in deploy.accessories,
             "#{@backup_path} names accessory #{inspect(backup.accessory)}, and #{@deploy_path} declares " <>
               "#{inspect(deploy.accessories)}. A backup config pointed at an accessory that does not " <>
               "exist is a config that cannot be reached."
    end

    test "the backup config is RENDERED, not a template — an unrendered app name hides every snapshot",
         %{
           backup: backup
         } do
      assert backup.app,
             "#{@backup_path} declares no `app:`. It is the snapshot path and the restic tag, and " <>
               "restic tracks it: renaming it orphans every existing snapshot."

      refute backup.erb?,
             "#{@backup_path} still carries an ERB tag. It is read with YAML.safe_load and never " <>
               "rendered, so `app: <%= service %>` would be taken literally and every snapshot would be " <>
               "written under a directory named after the tag. Copy kit's .erb and RENDER it."
    end

    test "the app name is the service name the deploy config derives from KIT_SERVICE", %{
      backup: backup,
      deploy: deploy
    } do
      assert deploy.service == "<%= service %>",
             "#{@deploy_path} declares `service: #{inspect(deploy.service)}` rather than the " <>
               "`<%= service %>` tag. kit's template derives both files' service name from KIT_SERVICE " <>
               "for exactly this reason: a hard-coded name in one file and an interpolated one in " <>
               "the other is a snapshot written under one name and restored under another."

      assert backup.app == "courier",
             "#{@backup_path} declares `app: #{inspect(backup.app)}`. The restic snapshot path and tag " <>
               "are built from it, so this is the string `kamal-backup list` filters on."
    end
  end

  describe "the two files are one contract" do
    test "every secret the backup config names is in the backup accessory's environment", %{
      backup: backup,
      deploy: deploy
    } do
      named = MapSet.new(backup.secrets)

      assert named != MapSet.new(),
             "#{@backup_path} names no secrets at all, so the reader found nothing and there is " <>
               "nothing to compare. An empty set agrees with every other empty set."

      missing =
        named
        |> MapSet.difference(MapSet.new(deploy.accessory_secrets[backup.accessory] || []))
        |> Enum.sort()

      assert missing == [],
             "#{@backup_path} names #{inspect(missing |> Enum.sort())}, and " <>
               "#{@deploy_path}'s #{inspect(backup.accessory)} accessory lists " <>
               "#{inspect(deploy.accessory_secrets[backup.accessory])}. `kamal-backup validate` builds " <>
               "the accessory's environment from that list and from nothing else, so a secret named in " <>
               "one file and missing from the other is a valid file in each and a failed validation of " <>
               "the pair — measured on kamal-backup 0.5.2, which reports " <>
               "\"RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required\"."
    end

    test "the secrets it names are the six the R2 and Postgres contract needs, and no others", %{
      backup: backup
    } do
      assert MapSet.new(backup.secrets) == MapSet.new(@permitted_secrets),
             "#{@backup_path} names #{inspect(Enum.sort(backup.secrets))}; the permitted set is " <>
               "#{inspect(@permitted_secrets)}. Every one of these is a NAME resolved from the accessory's " <>
               "environment, and the reader refuses a value in that position — so anything new here is " <>
               "either a credential in a committed file or a key this configuration does not understand."
    end

    test "the two R2 credentials are named in the accessory and NOT here, because no config key exists for them",
         %{backup: backup, deploy: deploy} do
      accessory = MapSet.new(deploy.accessory_secrets[backup.accessory] || [])

      for name <- @accessory_only_secrets do
        assert MapSet.member?(accessory, name),
               "#{@deploy_path}'s backup accessory does not list #{name}. A restic repository on R2 is " <>
                 "an S3 endpoint, so something has to authenticate against it."

        refute name in backup.secrets,
               "#{@backup_path} names #{name}. kamal-backup 0.5.2 has no configuration key for it — " <>
                 "`ConfigFile::TOP_LEVEL_KEYS` is app/accessory/databases/paths/restore_from/restic/" <>
                 "backup/state, and the AWS pair is in none of them — so a name here resolves to nothing " <>
                 "and reads as a credential in a committed file."
      end
    end

    test "the database connection uses the same variable name courier's release requires", %{
      backup: backup
    } do
      runtime = File.read!("config/runtime.exs")

      assert runtime =~ ~S|System.get_env("DATABASE_URL")|,
             "config/runtime.exs no longer reads DATABASE_URL, so the variable this backup config " <>
               "names is no longer courier's database. Re-read it before trusting either file."

      assert Enum.any?(backup.databases, &("DATABASE_URL" in &1.secrets)),
             "#{@backup_path} has no database whose `url` resolves from DATABASE_URL. `name` and " <>
               "`adapter` are a label and a dump method; the url is the connection, and a dump of " <>
               "something courier does not connect to is a dump nobody needs."
    end

    test "there is exactly one database, and it is postgres", %{backup: backup} do
      assert length(backup.databases) == 1,
             "#{@backup_path} declares #{length(backup.databases)} databases. courier's migrations " <>
               "create one schema and no second server, so a second entry would be a dump of " <>
               "something this service does not own — or, worse, the same database twice under two " <>
               "snapshot paths, one of which nobody restores from."

      assert [database] = backup.databases

      assert database.adapter == "postgres",
             "#{@backup_path} declares adapter #{inspect(database.adapter)}. `Courier.Repo` is the " <>
               "only database courier has, and it is PostgreSQL."

      assert database.name == "primary",
             "#{@backup_path} declares `name: #{inspect(database.name)}`. It is a LABEL for the " <>
               "snapshot path and the restic tag, not a database name — and restic tracks those paths, " <>
               "so renaming it orphans every existing snapshot."
    end

    test "the snapshot path is the one the runbook tells an operator to look for", %{
      backup: backup
    } do
      assert KamalConfig.snapshot_path!(backup, 1) == "databases/courier/primary/postgres.pgdump"
    end
  end

  describe "no key material, and no file paths" do
    test "COURIER_SECRET_BOX_KEY is not named — the dump carries ciphertext and the key lives elsewhere",
         %{
           backup: backup,
           deploy: deploy
         } do
      refute "COURIER_SECRET_BOX_KEY" in backup.secrets,
             "#{@backup_path} names COURIER_SECRET_BOX_KEY. The key that opens " <>
               "webhook_endpoints.secret is not in the database, so it cannot be in a dump of the " <>
               "database — and a snapshot encrypted under a key that rotates with the deployment is a " <>
               "snapshot that stops being readable the day the key does."

      refute MapSet.member?(
               MapSet.new(deploy.accessory_secrets[backup.accessory] || []),
               "COURIER_SECRET_BOX_KEY"
             ),
             "#{@deploy_path}'s #{inspect(backup.accessory)} accessory is given COURIER_SECRET_BOX_KEY. " <>
               "It needs no credential to run pg_dump and restic, and the sealing key is the one value " <>
               "a dump must never carry."

      runtime = File.read!("config/runtime.exs")

      assert runtime =~ ~S|System.get_env("COURIER_SECRET_BOX_KEY")|,
             "config/runtime.exs no longer reads COURIER_SECRET_BOX_KEY, so the whole SecretBox " <>
               "question has changed and README's answer to it is stale."
    end

    test "no file paths are declared, because courier keeps nothing on disk", %{backup: backup} do
      refute backup.paths?,
             "#{@backup_path} declares a `paths:` list, so restic takes a file snapshot of whatever it " <>
               "names. courier keeps no state on local disk: its migrations create no bytea column, no " <>
               "object-store key and no attachment table, and its image writes nothing to a volume. If " <>
               "that has changed, the honest move is to say which paths and why — not to leave a list " <>
               "that snapshots nothing while claiming to cover the disk."
    end

    test "no secret-shaped value appears in any line the tool reads" do
      lines = configured_lines()

      assert lines != [],
             "#{@backup_path} has no non-comment lines at all, so this test read nothing and " <>
               "would pass over a file of pure comments."

      for value <- secret_values() do
        offending = Enum.filter(lines, &String.contains?(&1, value))

        refute offending != [],
               "#{@backup_path} carries #{inspect(value)} in a line the tool reads: " <>
                 "#{inspect(offending)}. The file carries NAMES; the values live in .kamal/secrets and " <>
                 "nowhere else."
      end
    end
  end

  describe "the schedule, and the number README quotes" do
    test "the schedule is daily, and it is stated rather than inherited", %{backup: backup} do
      assert backup.schedule == "1d",
             "#{@backup_path} declares `backup.schedule: #{inspect(backup.schedule)}`. The schedule is " <>
               "the data-loss window quoted to a customer, and it is the one number in this file that " <>
               "is a promise rather than a mechanism."

      contents = File.read!(@backup_path)

      for {key, value} <- [
            {"keep_last", 7},
            {"keep_daily", 7},
            {"keep_weekly", 4},
            {"keep_monthly", 6},
            {"keep_yearly", 2}
          ] do
        assert contents =~ "#{key}: #{value}",
               "#{@backup_path} does not state #{key}: #{value}. These five happen to be " <>
                 "kamal-backup 0.5.2's defaults, which is exactly why they are written out: a retention " <>
                 "policy that lives in a dependency's default is a retention policy that changes when " <>
                 "their gem releases."
      end

      assert contents =~ "init_if_missing: true",
             "#{@backup_path} does not state init_if_missing: true. That is the difference between " <>
               "\"backups are on\" and \"backups are on after somebody created the repository\"."

      assert contents =~ "check_after_backup: true",
             "#{@backup_path} does not state check_after_backup: true. A repository that has been " <>
               "silently losing blocks is the failure this catches, and it is only detectable while " <>
               "there is still something to find."
    end

    test "README quotes the window this schedule produces, and says it is not PITR" do
      readme = File.read!(@readme)

      assert readme =~ "24 hours",
             "README.md does not state the data-loss window. With the shipped `1d` schedule, up to 24 " <>
               "hours of committed transactions are lost if the database is destroyed."

      assert readme =~ "not point-in-time recovery" or readme =~ "NOT point-in-time recovery",
             "README.md states the window but not that a scheduled dump is not PITR. The window IS the " <>
               "absence of PITR, and a reader told only \"24 hours\" cannot tell a backup from a " <>
               "replication target."

      assert readme =~ "finished" or readme =~ "previous backup",
             "README.md gives the window without saying it is measured from when the previous backup " <>
               "finished. The scheduler's loop is run-a-backup-then-sleep, so one cycle is the interval " <>
               "PLUS that run's duration, and the gap between two snapshots is never exactly 24 hours."
    end
  end

  describe "the migration command" do
    test "config/deploy.yml does not claim to run migrations, because Kamal 2 cannot" do
      deploy = File.read!(@deploy_path)

      refute deploy =~ ~r/^migrate:/m,
             "#{@deploy_path} declares a `migrate:` key. Kamal 2.12.0 rejects it outright " <>
               "(\"unknown key: migrate\"), so the document kamal reads would be a document kamal refuses."
    end
  end

  defp secret_values do
    [
      "postgres://",
      "ecto://",
      "r2.cloudflarestorage.com",
      "AKIA",
      "whsec_",
      "://courier:"
    ]
  end

  defp configured_lines do
    @backup_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
  end
end
