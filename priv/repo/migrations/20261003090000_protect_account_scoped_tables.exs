defmodule Courier.Repo.Migrations.ProtectAccountScopedTables do
  use Ecto.Migration

  @moduledoc """
  courier's account boundary, enforced by Postgres instead of by hand-written
  predicates. One migration, three calls, and the substrate from kit underneath
  them.

  ## WHAT WAS TRUE BEFORE THIS FILE, MEASURED

  Every account-scoped read in courier was an Ecto query that filtered by
  `account_id` in Elixir. Postgres was told nothing. No file in
  `priv/repo/migrations` mentioned row level security, `create policy` or
  `force` — so a query that dropped its predicate would have returned every
  account's rows with no database object standing in the way.

  Nothing was broken. This file removes the condition under which a refactor
  becomes an incident with nothing left to catch it.

  ## WHY THE SUBSTRATE AND NOT HAND-WRITTEN POLICIES

  `select anywaye.protect_table(...)`, from kit's
  `templates/database/tenancy/substrate.sql`, copied verbatim. `identity` did
  the same thing in `migrations/00016_account_isolation.sql`, and a second
  dialect of row-level security in one fleet is a dialect the next reader does
  not recognise.

  Copied from kit at `537441eee96254c34b448e9d98f334a20df89213`, the commit
  that added the caller scope (`begin_user`/`current_user_id`,
  `membership_tables`/`protect_membership_table`); the same bytes also carry
  kit's earlier `protect_table` sequence grant (`63663f8`). It is kit's
  template byte for byte, sha256
  `eaab2893825647495ee0db770841ac60fe855791b148423430ca44db1f8334c2`. **NOTE
  that this repository's own `kit.ref` (`f6d3b74`) predates the substrate** —
  the tenancy templates were added to kit later, in `e8605c9`. So the
  substrate below is newer than the kit commit this repository pins, and
  pinning is a decision this packet did not make: moving `kit.ref` changes the
  whole stack, not one migration. Reported rather than done.

  ## THE THREE TABLES, AND HOW THEY WERE DETERMINED

  Read out of `information_schema` on a migrated database, not guessed from the
  migrations: every table in `public` with an `account_id` column. Four tables
  qualified. Three are protected here.

  | table | why it is account-scoped |
  | --- | --- |
  | `idempotency_keys` | `account_id uuid null: false`, and the row carries a cached HTTP response body — a cross-account read returns **another customer's response**, not merely an identifier |
  | `notification_preferences` | `account_id uuid NOT NULL`, added in `20261001094451`, and the only tenancy key on a user's answers |
  | `webhook_endpoints` | `account_id uuid null: false`, and a row holds a sealed signing secret |

  ## THE FOURTH ACCOUNT-SCOPED TABLE, DELIBERATELY NOT PROTECTED

  **`outbox_events` has an `account_id` column and is NOT protected.** This is a
  decision, and it is the opposite of an oversight, so it is recorded in the
  database rather than only here.

  The column is **nullable on purpose** — `20260930075429` documents that
  `Courier.Deliver` records `email.delivered` for a *user* and courier does not
  know which account that user is in. `protect_table` writes
  `with check (account_id = (select anywaye.current_account_id()))`, and
  `account_id = NULL` is never true. Protecting this table therefore **refuses
  every such insert with `42501`**, and the relay would additionally read zero
  rows: `DispatchWebhooksWorker` scans `webhooks_dispatched_at IS NULL` across
  *all* accounts, which is the shape of a worker rather than of a request.

  So this is not "the fourth table we forgot". It is a table whose owner is a
  background process with no request identity, and the substrate has no answer
  for that: a per-account policy on a table read cross-account by design either
  hides the work or needs a `SECURITY DEFINER` escape hatch, and inventing that
  here is the second dialect this migration exists to avoid. `anywaye`'s
  `unprotected_tables()` sweep will name `outbox_events` on every run, and that
  is the correct answer from it: courier holds account data in a
  request-less place.

  ## THE TABLES WITH NO `account_id` AT ALL

  `email_suppressions`, `unsubscribe_tokens`, `webhook_deliveries`, `oban_jobs`,
  `oban_peers`, `schema_migrations` — measured absent. `protect_table` refuses a
  table with no tenancy column by name, which is the right answer for all of
  them. `email_suppressions` is the one that looks like a gap: it has **no
  `account_id` by design**, because a suppression is a fact about a *mailbox*
  and belongs to whoever mailed it — so it is fleet-wide on purpose, and that is
  recorded in `tenancy.yml`.

  `webhook_deliveries` is the one worth naming: it has no `account_id` and reads
  by `webhook_endpoint_id`. Its endpoint IS protected, so a delivery cannot leak
  an endpoint's URL or secret; what it carries is a delivery attempt's own
  status. Reported, not protected.

  ## WHAT THIS MIGRATION DOES NOT DO, AND THAT IS THE POINT

  It does not call `anywaye.begin_account/1`. It installs the boundary; courier
  does not yet turn it on per request. **Until it does, courier's own reads of
  these three tables go through as the role that owns them**, which is why
  nothing in the Elixir suite changed behaviour here — see
  `REPORT-courier-row-level-security` §3 for the measurement, which is the
  reason this file is safe to land alone.

  `identity` made the same split, in the same order, and called the next step
  "the application switching to that role is the NEXT packet".
  """

  @substrate_sha "537441eee96254c34b448e9d98f334a20df89213"

  def up do
    provision_login_role()

    execute_all(substrate())

    # A CACHED CUSTOMER HTTP RESPONSE. The row stores `response_body` and
    # `response_status`, so a query that lost its `account_id` returns another
    # account's response body. The unique index is already
    # `(account_id, endpoint, idempotency_key)`, and `protect_table` adds the
    # `account_id`-leading index the policy filters on.
    execute("select anywaye.protect_table('idempotency_keys', 'courier_app')")

    # ONE ANSWER PER PERSON, and the column says who may be entitled to it.
    # `Courier.NotificationPreferences.enabled?/3` takes no account on purpose
    # (the unique index is `(user_id, notification_type)`), so a delivery read
    # needs an identity that a request does not have. That is the same shape as
    # `outbox_events` below and it is the reason this is called out: protecting
    # the table makes the policy require an identity, and the identity-less read
    # reads zero rows. Safe — but it means this table is protected and NOT yet
    # switched on, which is the state this migration leaves it in.
    execute("select anywaye.protect_table('notification_preferences', 'courier_app')")

    # A SEALED SIGNING SECRET. `Courier.SecretBox` puts ciphertext in
    # `secret`, and the plaintext exists in one 201 and in the signing process.
    # Another account's endpoint row is another account's webhook destination.
    execute("select anywaye.protect_table('webhook_endpoints', 'courier_app')")
  end

  def down do
    # `disable` BEFORE `drop policy`: a table with policies and RLS off hides
    # nothing, but a table with policies and RLS *off* mid-sequence would leave
    # three tables unreadable between the two statements. Same order, same
    # reason, as `identity`'s 00016 Down.
    execute("alter table idempotency_keys disable row level security")
    execute("alter table notification_preferences disable row level security")
    execute("alter table webhook_endpoints disable row level security")

    for table <- ~w(idempotency_keys notification_preferences webhook_endpoints) do
      for command <- ~w(select insert update delete) do
        execute("drop policy if exists #{table}_anywaye_#{command} on #{table}")
      end
    end

    for table <- ~w(idempotency_keys notification_preferences webhook_endpoints) do
      execute("drop index if exists #{table}_anywaye_account_id_idx")
    end

    execute("drop schema if exists anywaye cascade")
  end

  # The login role, provisioned if the cluster has not.
  #
  # `protect_table` REFUSES to run without it, by name, and that refusal is
  # correct: a policy written `to courier_app` for a role that does not exist is
  # a policy nobody holds. `identity` relies on kit's cluster provisioning
  # `identity_app` from `KIT_POSTGRES_DATABASES`. courier cannot rely on the
  # same thing, and the reason is measured rather than theoretical: courier's
  # **test** database is a plain postgres where the only role is `postgres`
  # (verified: `rolname=postgres, rolsuper=t, rolbypassrls=t`), so without this
  # block the migration fails to apply in `mix test` and the boundary never
  # lands anywhere it is exercised.
  #
  # Attributes copied from kit's `templates/compose/postgres/initdb/10-cluster.sh`
  # so a role this migration creates and a role the cluster provisions are the
  # same role. `NO BYPASSRLS` is the one that matters most: a login role with
  # `BYPASSRLS` would hold the DML grant and skip the policies entirely, which
  # is the failure every policy in this migration exists to prevent.
  defp provision_login_role do
    execute_all("""
    do $$
    begin
      if not exists (select 1 from pg_roles where rolname = 'courier_app') then
        create role courier_app login nosuperuser nobypassrls nocreatedb nocreaterole noreplication;
      end if;
    end
    $$;
    """)
  end

  # ONE FILE, ONE `execute` EACH.
  #
  # `identity` gets this for free: goose hands `StatementBegin`/`StatementEnd`
  # blocks to Postgres as ONE query over the simple protocol, which accepts
  # several commands. Ecto does not — `execute/1` reaches Postgrex as a prepared
  # statement, and the answer is measured rather than remembered:
  #
  #     ** (Postgrex.Error) ERROR 42601 (syntax_error)
  #        cannot insert multiple commands into a prepared statement
  #
  # So the substrate arrives as one verbatim file and leaves as one statement at
  # a time. **The splitter is not allowed to be clever.** It tracks four states
  # and a dollar-quote tag, and a `;` ends a statement only outside all of them.
  # A `String.split(sql, ";")` would cut every function body in half at the
  # first `;` inside `$caf$`, which is a syntax error whose message names a line
  # in kit's file rather than in this one.
  #
  # It is not left unverified either: the proof that this splitter is right is
  # that `mix ecto.migrate` applies to a **fresh** database and leaves a catalog
  # identical to the one `psql -f` produces — same `relrowsecurity`, same
  # `relforcerowsecurity`, same policy names. A splitter that dropped a
  # statement would apply cleanly and leave a table unprotected, which is
  # precisely the "a check over nothing passes" shape, so the verification is
  # the catalog and not the exit code.
  defp execute_all(sql) do
    sql
    |> statements()
    |> Enum.each(&execute/1)
  end

  # @doc false
  def statements(sql) do
    sql
    |> String.to_charlist()
    |> scan(:code, [], [])
    |> Enum.reverse()
    |> Enum.map(&(&1 |> List.to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  # `cur` is the statement being built, reversed. `acc` holds finished
  # statements, reversed, so both stay O(1) per character and the whole 30 KB
  # file splits without ever copying a prefix.
  #
  # FIVE STATES, and each one exists because kit's file contains it: a `--`
  # comment carrying an apostrophe, a `hint` string carrying a semicolon, and
  # nine `$caf$` bodies carrying every `;` in the substrate.
  defp scan([], _state, cur, acc), do: push(cur, acc)

  defp scan([?; | rest], :code, cur, acc), do: scan(rest, :code, [], push(cur, acc))

  # A line comment. **This clause did not match a line comment as it was
  # written.** `[?- = ?-, rest]` is a TWO-ELEMENT list pattern — element zero is
  # constrained to `?-`, element one is bound to `rest` — not a cons. Measured:
  #
  #     scan(~c"-- a line comment\nnext\n") -> fell through to the catch-all
  #     scan(~c"--")                     -> {:MATCHED_2, 45}
  #
  # so on a real comment it never ran (the `;` inside one would have ended the
  # statement early), and on the one input it DID match — a list of exactly two
  # dashes — it handed `until_newline/2` the integer `45` instead of a list and
  # raised `CaseClauseError`. kit's substrate has 526 comment lines and 86
  # semicolons, and one of them landed on the `--` that is the last two
  # characters of the file.
  #
  # `?/` and `?*` in the clause below had the same shape for a different reason
  # and were unreachable outright: `?/ = ?*` is `47 = 42`, so the compiler said
  # "pattern cannot possibly match" every time this file was compiled — which
  # nobody read, because nothing had ever compiled this file either. kit's
  # substrate has no `/*` at all, so that clause is correct and unreachable.
  defp scan([?-, ?- | rest], :code, cur, acc) do
    {skip, rest} = until_newline(rest, [])
    # `--` and the newline are re-emitted, and both go in FRONT of the comment
    # text: `X ++ cur` ends up as `... ++ Enum.reverse(X)`, and `skip` is
    # already reversed, so `[?\n | skip] ++ ~c"--"` reverses to exactly
    # `"--" ++ <the text> ++ "\n"`.
    #
    # BOTH were missing once. Emitting the comment bare left the first
    # statement starting with substrate.sql's prose and Postgres answered
    # `42601 syntax error at or near "kit"`; re-emitting `--` without the
    # newline made every comment run on into the SQL after it, which is what
    # `--` does by definition, and Postgres answered `42601 syntax error at
    # near "returns"`. A line comment is only a line comment if the line ends.
    scan(rest, :code, [?\n | skip] ++ ~c"--" ++ cur, acc)
  end

  # THERE IS NO `/*` BRANCH, and that is a decision rather than an omission.

  # The version this file inherited had one, written `[?/ = ?*, rest]`, which
  # is not a two-character match at all: it reads as "the head is `?/`, and the
  # head is also `?*`", and `?/` is 47 while `?*` is 42. The compiler reported
  # `pattern cannot possibly match` on every compile. Nothing had ever compiled
  # this migration, so nobody saw the warning the compiler was repeating.

  # It was unreachable, so it was also untested, and kit's substrate contains
  # **zero** `/*` (measured: `grep -c '/\*'` is 0). A branch that cannot execute
  # is a branch nobody has run, and this file's own rule is that the splitter is
  # not allowed to be clever. Deleting it is safe *because* `substrate/0` now
  # pins the sha256: any substrate edit that introduced a `/*` fails the digest
  # check before this code is ever reached, so the missing branch cannot become
  # a silent mis-split — it becomes a migration that refuses to run and names
  # the file.

  # A doubled quote is one quote, which is the only escape a single-quoted
  # string has in standard SQL and the one kit's `hint` messages rely on.
  defp scan([?' | rest], state, cur, acc) when state in [:code, :single] do
    scan(rest, if(state == :code, do: :single, else: :code), [?' | cur], acc)
  end

  defp scan([?$ | rest], :code, cur, acc) do
    case dollar_tag(rest, []) do
      {:ok, tag, rest} ->
        {body, rest} = until_dollar(rest, tag, [])

        # `tag` is the tag's INNER text, so the delimiter is `[?$ | tag]` — the
        # opening `$` was consumed by this clause's head and has to be put back.
        # The version this replaces emitted `Enum.reverse(tag)`, which is the
        # delimiter MINUS one `$`: `$$` came out as `$` and `$caf$` came out as
        # `$fac`, and **Postgres rejects both**. That failure was invisible
        # while `until_dollar/3` could not find a closer, because it raised
        # first; fixing the search without fixing the reconstruction only moved
        # the crash.
        #
        # Twice, and the order is the reverse accumulator's: `X ++ cur` puts `X`
        # at the END of the finished statement, REVERSED, so each delimiter is
        # handed over as `Enum.reverse/1` of itself. Output therefore reads
        # `... cur ++ $caf$ ++ body ++ $caf$ ...`, with the opener landing right
        # after the `as ` that introduced the body.
        delimiter = [?$ | tag]

        scan(
          rest,
          :code,
          Enum.reverse(delimiter) ++ Enum.reverse(body) ++ Enum.reverse(delimiter) ++ cur,
          acc
        )

      :none ->
        scan(rest, :code, [?$ | cur], acc)
    end
  end

  defp scan([char | rest], _state, cur, acc), do: scan(rest, :code, [char | cur], acc)

  defp push([], acc), do: acc
  defp push(cur, acc), do: [Enum.reverse(cur) | acc]

  defp dollar_tag([?$ | rest], tag), do: {:ok, Enum.reverse([?$ | tag]), rest}

  defp dollar_tag([char | rest], tag)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_ do
    dollar_tag(rest, [char | tag])
  end

  defp dollar_tag(_rest, _tag), do: :none

  # FIND THE CLOSING DOLLAR QUOTE.
  #
  # `tag` is the tag's INNER text — `"caf$"` for `$caf$`, `"$"` for `$$` —
  # because `scan/4` already consumed the opening `$`. So the closing
  # delimiter is the literal sequence `[?$ | tag]`, and this walks forward one
  # character at a time comparing that LIST against the tail.
  #
  # **The version this replaces could never find a closer, so it always ran to
  # the end of the input and raised `FunctionClauseError` on `[]`.** It read
  #
  #     defp until_dollar([?$ | rest], tag, acc) do
  #       case rest do
  #         [^tag | tail] -> {Enum.reverse(acc), tail}
  #         _ -> until_dollar(rest, tag, acc)
  #       end
  #     end
  #
  # and `^tag` puts the pinned charlist in the FIRST ELEMENT position, where it
  # is compared against a single character. `^tag` is `~c"$"` — the list `[36]`
  # — and the element it meets is the integer `36`. `[36] != 36`. Measured:
  #
  #     tag = ~c"$"
  #     case ~c"$;\n" do [^tag | _] -> :matched; _ -> :no_match end
  #     #=> :no_match
  #
  # so `scan/4` fell through both clauses of `until_dollar/3` on the closing
  # delimiter, every `$$` in the file was swallowed, and the lexer died on EOF
  # 38 characters into the FIRST dollar-quoted body — the `create role` block
  # in `provision_login_role/0`, which is why the crash named that function and
  # not the substrate it was supposed to be reading.
  #
  # The second half of the same bug was the `_` branch, which advanced `rest`
  # and DROPPED the `$` it had just consumed, so even a working match would
  # have silently deleted stray dollar signs from the emitted SQL.
  defp until_dollar(rest, tag, acc) do
    delimiter = [?$ | tag]

    cond do
      # The closing delimiter, matched as a PREFIX. `List.starts_with?/2` and not
      # a pin: a pin compares the WHOLE remaining list against the delimiter, so
      # `^delimiter` only ever matches when the file ends immediately after the
      # closer — which is the one case where a dollar quote is not closed at all.
      List.starts_with?(rest, delimiter) ->
        {Enum.reverse(acc), Enum.drop(rest, length(delimiter))}

      match?([_ | _], rest) ->
        [char | tail] = rest
        until_dollar(tail, tag, [char | acc])

      true ->
        raise ArgumentError,
              "the substrate ended inside a dollar-quoted body (tag #{inspect(tag)}), " <>
                "so the closing delimiter #{inspect(List.to_string(delimiter))} was never found. " <>
                "A dollar quote opened in kit's file must close in kit's file."
    end
  end

  defp until_newline(rest, acc) do
    case rest do
      [?\n | tail] -> {acc, tail}
      [char | tail] -> until_newline(tail, [char | acc])
      [] -> {acc, []}
    end
  end

  # kit's substrate, verbatim, at @substrate_sha. `$caf$` survives as written
  # because inside one quoted string the whole block reaches Postgres as ONE
  # statement over the simple protocol, and Postgres parses dollar quoting
  # correctly. Re-tagging the quotes to `$$` would work and would also be a
  # fork of the shared substrate, which is the thing kit's template means by
  # "a template that offers one is a template the weaker one gets chosen from".
  #
  # **AND THE SHA IS CHECKED, because a comment is not a claim.** The attribute
  # was previously set and never read, which the compiler said out loud
  # ("@substrate_sha was set but never used") and which meant the provenance
  # claim in this file's own header was prose. It is now the thing that decides
  # whether the migration runs at all: a hand-edited substrate, a kit upgrade
  # that changes the file, or a bad copy fails here with the two digests named,
  # instead of quietly installing policies from a file nobody has re-read.
  #
  # Measured on the file this branch carries:
  #
  #     git -C ../kit show 537441e:templates/database/tenancy/substrate.sql \
  #       | diff - priv/repo/substrate.sql
  #     #=> (no output)
  #     shasum -a 256  # both sides
  #     #=> eaab2893825647495ee0db770841ac60fe855791b148423430ca44db1f8334c2
  defp substrate do
    path = Path.join(__DIR__, "../substrate.sql")
    bytes = File.read!(path)
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    expected = "eaab2893825647495ee0db770841ac60fe855791b148423430ca44db1f8334c2"

    if digest != expected do
      raise """
      priv/repo/substrate.sql is not the substrate @substrate_sha claims.

        @substrate_sha  #{@substrate_sha}
        expected sha256 #{expected}
        actual   sha256 #{digest}
        file            #{path}

      Either the copy drifted or the file is not kit's. Do not edit it to make
      this pass — re-copy it:

        git -C ../kit show #{@substrate_sha}:templates/database/tenancy/substrate.sql \
          > #{path}
      """
    end

    bytes
  end
end
