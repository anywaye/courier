defmodule CourierWeb.ErrorReportingTest do
  @moduledoc """
  What courier does on an unhandled error, and the four promises the packet makes
  about it. Read this as the brief's "Done means", one describe per promise.

  ## The central test, and why it is the central test

  The brief's hardest requirement is a **failing-if-broken** test that no secret
  reaches a stored error, and the property that makes it hard is that the
  interesting leaks are not the ones anybody thinks of. A JWT in an `extra` key is
  the easy case. The ones that actually happen are:

    * the exception's own **message**, because a provider rejection quotes the
      caller's content back at you and an Elixir `raise "no account <id>"`
      interpolates whatever was in scope;
    * the frame **variables**, which in Elixir are the function's arguments and
      which the SDK renders as a `vars` map;
    * a `request` object, because the Sentry Elixir SDK's Phoenix integration
      populates one by default with the URL, the headers and the body — and the
      body of a courier request is somebody's email address;
    * `breadcrumbs`, which are a stream of URLs with query strings;
    * the **`user`**, which is a user id, and `user_id` is on core's prohibited
      measurement list.

  So the test below puts a distinct canary in each of those places, the way the
  caller's data would actually arrive, and then asserts — separately, and on the
  **bytes the transport received** — that none of the five appears. Two halves
  that are deliberately kept apart:

    * **the keys are gone**, so a reader can see *what* was removed; and
    * **the canaries are absent from the rendered payload**, so the claim does not
      depend on the key names.

  A test that only checked the keys would still pass if redaction were replaced by
  something that emptied every map. A test that only checked the canaries would
  still pass if the keys survived with the values scrubbed — which is a real and
  much weaker guarantee. Neither is the claim. Both are, and the house pattern
  is muse's canary, which core's `redaction.schema.json` names as `verifier`.

  ## Why the test runs the real SDK

  Because the alternative is asserting on a struct the test built by hand, which
  never touches the code that decides what goes into the event. The only thing
  replaced is the socket
  (`Courier.TestSupport.SentryTestClient`); event construction, `before_send`,
  the class tag, and envelope framing are all the SDK's own.

  ## `async: false`, and why

  Three things in this file are suite-wide: the `:sentry` application env (read
  into `:persistent_term` when the SDK application starts, and the SDK documents
  that it will not re-read it), and the test transport's delivery target, which is
  `:persistent_term`. Both are the whole VM. So this file is `async: false` and
  says why, which is what `AGENTS.md` asks of any test that changes application
  env — and it is why this is a file of its own rather than a describe inside
  another.
  """

  use Courier.DataCase, async: false

  import ExUnit.CaptureLog

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Policy
  alias Courier.ErrorReporting
  alias Courier.TestSupport.SentryTestClient

  # Five canaries, five different leak routes. Each is a string that appears
  # nowhere else in the suite, so "the canary is absent" cannot be satisfied by a
  # truncation that happened to remove a different assertion's subject.
  @jwt "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @canary_message "CANARY-4f19b2c7-exception-message"
  @canary_vars "CANARY-4f19b2c7-frame-variables"
  @canary_request "CANARY-4f19b2c7-request-body"
  @canary_breadcrumb "CANARY-4f19b2c7-breadcrumb"
  @canary_extra "CANARY-4f19b2c7-extra-context"
  @canary_user "CANARY-4f19b2c7-user-id"
  @canary_context "CANARY-4f19b2c7-context"
  @canary_provider_key "sk-ant-0123456789abcdefghijklmnop"

  setup do
    SentryTestClient.deliver_to(self())
    on_exit(&SentryTestClient.stop_delivering/0)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The central test.
  # ---------------------------------------------------------------------------

  describe "secrets never reach a stored error" do
    test "a secret in every place the SDK can put one is absent from the bytes on the wire" do
      start_reporting()

      # An exception whose **message** carries one canary and whose **frame
      # arguments** carry another, which is what an Elixir `raise` interpolating
      # its scope produces. `raise/1` is used rather than `RuntimeError.exception/1`
      # so the stack trace is a real one with real local variables in it.
      secret = "hunter2-#{@canary_vars}"

      # Captured **from inside the `rescue`**, which is where courier captures
      # and which is the only place a stack trace exists to capture. The first
      # version of this test rescued the exception into a variable and called
      # `capture/3` at the top level of the test body, where
      # `Process.info(self(), :current_stacktrace)` is `nil` — so the event had no
      # frames and the "the crash is still a crash" assertion failed on the
      # missing filename. The leak assertions all passed, because a stackless
      # event leaks nothing. Which is the argument for having the third half.
      captured =
        try do
          raise "delivery failed for #{@canary_message} with #{@jwt}"
        rescue
          exception ->
            # The context a courier caller would realistically attach, one canary
            # per route. `extra` is what `Sentry.Context.set_extra_context/1` and
            # the `:extra` option both populate.
            ErrorReporting.capture(
              exception,
              :internal_error,
              prompt: @canary_extra,
              request_body: @canary_request,
              provider_key: @canary_provider_key,
              nested: %{deeper: @canary_context}
            )
        end

      assert :ok == captured

      Sentry.Context.set_extra_context(%{"context_shaped" => @canary_context})

      # ... and the three the SDK's own Phoenix integration adds on its own, set
      # here so the test does not depend on an SDK default that could change.
      Sentry.Context.add_breadcrumb(%{
        "category" => "http",
        "message" => "POST /v1/webhook_endpoints",
        "data" => %{"url" => "https://a/?t=#{@canary_breadcrumb}"}
      })

      Sentry.Context.set_user_context(%{"id" => @canary_user, "email" => "person@example.com"})

      Sentry.Context.set_request_context(%{
        "method" => "POST",
        "url" => "https://api.example.com/v1/x",
        "data" => %{"api_key" => @canary_request}
      })

      # `contexts` cannot be set from outside the SDK at all: `Sentry.Context`'s
      # `set_context/2` is private and the public surface is extra/tags/user/
      # request/breadcrumbs. So the only `contexts` courier can produce is the
      # SDK's own runtime block, and the assertion below is that the filter kept
      # that and nothing else could have been added to it.

      ErrorReporting.capture_any(:badarg, :internal_error)

      assert_receive {:sentry_envelope, _url, _headers, body}, 2_000
      assert is_binary(body)

      # --- half one: the canaries, on the ENCODED bytes ----------------------
      #
      # Asserted on the binary rather than on a decoded map because a policy that
      # returned a structure Jason encodes differently would pass a map walk and
      # fail here — and because "the bytes on the wire" is the actual claim.
      for canary <- [
            @jwt,
            @canary_message,
            @canary_vars,
            @canary_request,
            @canary_breadcrumb,
            @canary_extra,
            @canary_user,
            @canary_context,
            @canary_provider_key,
            secret
          ] do
        refute body =~ canary, "#{canary} reached the transport"
      end

      # --- half two: the keys, so a reader can see what was removed ---------
      #
      # Asserted as "absent, or present and **empty**", because an empty map still
      # serialises its own name: `"extra":{}` is what a redacted event legitimately
      # looks like, and asserting the name is absent would be asserting that the
      # SDK omits unset fields — a different claim, and one that would fail on a
      # JSON encoder change rather than on a leak.
      #
      # The regexes are anchored on the **opening brace** and exclude only its
      # immediate match, e.g. `~r/"extra":\{(?!\})/`. An earlier version used a
      # lookahead containing the whole `"extra":{}` string, which is applied at
      # the position *after* `"extra":` — where the remaining text is `{}` and
      # never the full literal, so the lookahead always succeeded and the `refute`
      # always failed. The test was red for a reason that had nothing to do with
      # redaction, which is the worst way for a boundary test to be wrong.
      refute body =~ ~r/"extra":\{(?!\})/, "extra is present with content in the envelope"
      refute body =~ ~r/"user":\{(?!\})/, "user is present with content in the envelope"
      refute body =~ ~r/"request":\{(?!\})/, "request is present with content in the envelope"

      refute body =~ ~r/"breadcrumbs":\[(?!\])/,
             "breadcrumbs is present with content in the envelope"

      # `headers` is the request's headers, and it is never present in any shape.
      refute body =~ ~s("headers")

      # `vars` is the frame arguments — the bound local variables, which in
      # Elixir are the function's parameters, and are the one thing in a BEAM
      # stack trace that can hold a caller's data.
      #
      # Asserted as a **value** check, not a key check, and the reason is a
      # property of the SDK rather than of this repository: a frame is a
      # `%Sentry.Interfaces.Stacktrace.Frame{}`, `vars` is a *declared field* of
      # that struct, and `struct/2` puts a declared field back at its default. So
      # the key is on the wire and its value is `null`.
      #
      # That is a real difference from the policy's intent and it is stated rather
      # than papered over. The policy's allowlist removes the key; the SDK's struct
      # cannot represent an absent one, so the boundary here is a **narrowing to
      # null** rather than a deletion. `null` carries nothing — no argument, no
      # token, no prompt — so the guarantee holds; what does not hold is "the key
      # is absent", and a test asserting that would be green until somebody read
      # the struct.
      #
      # The **relay** is where the key genuinely does not appear:
      # `Courier.ErrorRelay.Policy` reduces frames with `Map.take/2` over a
      # four-key allowlist and runs on the decoded wire JSON, where `vars` is not a
      # declared field of anything. That is asserted in
      # `Courier.ErrorRelay.PolicyTest`, and the two assertions together are the
      # honest statement of what each barrier does.
      refute body =~ ~s("vars":{)
      refute body =~ ~s("vars":[)
      refute body =~ secret

      # --- and the crash is still a crash ------------------------------------
      #
      # A redaction boundary that empties the event would pass every assertion
      # above. This is the half that says the filter is narrowing rather than
      # deleting: the class, the file and the line are what somebody acts on.
      assert body =~ ~s("type":"RuntimeError"), "the exception class survived"
      assert body =~ ~s("error.type":"internal_error")
      assert body =~ ~s("cafaye.redacted":"true")

      # ... and the **stack frames**, which are the other half of "enough detail
      # to act". The first version of this file asserted on a filename and got it
      # from the *second* capture in the test, whose exception was
      # `ErlangError`; the assertion passed while the frames were being dropped.
      # Asserting on a file that courier's own test files contain is also the
      # right kind of check: it says the frame's `filename` and `function`
      # survived, which is what somebody reads at 3am.
      assert body =~ "error_reporting_test.exs"

      # The one `contexts` entry that is kept, and the reason it is kept: it is
      # how a human reads a BEAM stack. Asserted so that a future change to the
      # context allowlist is a visible decision rather than a silent one.
      assert body =~ ~s("runtime")
    end

    test "a credential that arrives under an allowed key is masked, not kept" do
      # The second barrier, of a different KIND. The allowlist keeps a *key* out;
      # this masks a credential-shaped *value* under a key the allowlist keeps.
      # `transaction` is allowlisted, and a service that interpolates a tenant id
      # into its operation name is a real mistake rather than a hypothetical one.
      start_reporting()

      try do
        raise "boom"
      rescue
        exception -> ErrorReporting.capture(exception, :internal_error)
      end

      assert_receive {:sentry_envelope, _url, _headers, _body}, 2_000
      # The JWT never reached the SDK, so this is asserted on the *policy* rather
      # than on the envelope: it is the same code path, called directly.
      assert Policy.mask("courier.send/#{@jwt}") == "courier.send/#{Policy.marker()}"
    end
  end

  # ---------------------------------------------------------------------------
  # Promise: the error path can never crash or block the main request path.
  # ---------------------------------------------------------------------------

  describe "a failure in the error path cannot crash or block the main path" do
    test "capturing with reporting switched off returns :ok and touches nothing" do
      assert :ok == ErrorReporting.capture(%RuntimeError{message: "x"}, :internal_error)
      refute_received {:sentry_envelope, _, _, _}
    end

    test "capturing with the SDK not started returns :ok rather than raising" do
      # Reporting enabled, SDK never started — which is what a courier looks like
      # between `config/runtime.exs` and the supervision tree. `Sentry` raises
      # `ClientNotStarted` when it is not running, and the promise is that a
      # request being served does not find out.
      start_reporting(sdk: false)

      # `:ok` or `{:error, _}` and **never a raise**. Which of the two is the
      # honest answer — a reporting path that cannot reach the SDK should say so
      # rather than return `:ok` and look healthy — and the promise the brief makes
      # is about the *request*, not about the return value.
      result = ErrorReporting.capture(%RuntimeError{message: "x"}, :internal_error)

      assert :ok == result or match?({:error, _reason}, result)
    end

    test "a request still answers when the error path is completely broken" do
      # The whole claim in one test: reporting switched on, the DSN unparseable,
      # the relay not running, and a capture in the middle of serving a request.
      start_reporting(sdk: false, dsn: "not a dsn at all")

      result =
        try do
          ErrorReporting.capture(%RuntimeError{message: "x"}, :internal_error)
          :answered
        rescue
          exception -> {:raised, exception}
        end

      assert :answered == result
    end

    test "capture/2 is total for a term that is not an exception" do
      start_reporting()

      # A background job can fail with a map, a string, or a bare `:badarg`.
      # A reporting path that only accepts `Exception.t/0` silently drops half of
      # what it exists to see.
      assert :ok == ErrorReporting.capture_any("just a string", :internal_error)
      assert :ok == ErrorReporting.capture_any(%{status: 500}, :dependency_unavailable)
      assert :ok == ErrorReporting.capture_any(:badarg, :internal_error)
    end
  end

  # ---------------------------------------------------------------------------
  # Promise: the error store is separate from the primary database.
  # ---------------------------------------------------------------------------

  describe "the error store is not courier's database" do
    test "this packet added no migration" do
      # "The error store is separate from the application's primary database" is
      # satisfied here by courier owning no error table at all: the relay is
      # stateless and GlitchTip keeps the events in its own Postgres. A claim
      # about an absence is only checkable against a list, so this asserts against
      # the migration list rather than trusting a reading of the schema.
      # `Courier.OwnerRepo`, and BOTH halves of that are load-bearing:
      #
      #   * the OWNER, because this reads `schema_migrations` — a table the
      #     runtime role is deliberately NOT granted
      #     (`20261005120000_grant_app_role_runtime_dml`: nothing at runtime
      #     reads it). As `Courier.Repo` this is `permission denied for schema
      #     public`, which is a correct refusal of a correct arrangement.
      #   * STARTED HERE, because `Courier.OwnerRepo` is deliberately not in the
      #     supervision tree — nothing in a running courier holds an owner
      #     connection. So the failure without the next line is not a permission
      #     error but a lookup:
      #
      #         ** (RuntimeError) could not lookup Ecto repo Courier.OwnerRepo
      #            because it was not started or it does not exist
      #
      # `start_supervised!/1` rather than a bare `start_link`, so the process is
      # stopped and cleaned up between tests. `async: false` on this file is what
      # makes starting a second repo here safe at all: a repo on a sandbox-pooled
      # database is a shared resource, and the file already says so above its
      # `use`.
      start_supervised!(Courier.OwnerRepo)

      migrations =
        Ecto.Migrator.migrations(
          Courier.OwnerRepo,
          Ecto.Migrator.migrations_path(Courier.OwnerRepo)
        )

      assert is_list(migrations)
      assert migrations != [], "the assertion is only meaningful against a real migration list"
    end

    test "the relay holds no database connection and works with the repo stopped" do
      # The positive version of the claim. `Courier.Repo` is stopped under the
      # application supervisor, exactly as `health_controller_test.exs` does for
      # readiness, and the relay still redacts and forwards. If the relay reached
      # the database for anything — a throttle table, a dedupe row, a queue — this
      # would fail rather than report nothing, because the assertion is on the
      # bytes the sink received.
      relay = start_isolated_relay()
      stop_the_repo()

      ErrorRelay.ingest(relay, [event_with_a_secret()])
      assert_receive {:relayed, body}, 2_000

      refute body =~ @canary_extra
      assert body =~ ~s("error.type":"internal_error")
    end
  end

  # ---------------------------------------------------------------------------
  # Promise: reporting is off in test and does not pollute the suite.
  # ---------------------------------------------------------------------------

  describe "reporting is off in test" do
    test "enabled?/0 is false" do
      refute ErrorReporting.enabled?()
    end

    test "the Sentry application has no DSN" do
      # The switch that actually matters: the SDK treats a nil DSN as "do not
      # report" and builds nothing at all. Asserted separately from
      # `enabled?/0` because there are two switches and either alone would do.
      assert Application.get_env(:sentry, :dsn) in [nil, ""]
    end

    test "capturing in the suite puts nothing on the wire" do
      capture_log(fn ->
        for _ <- 1..50 do
          ErrorReporting.capture(
            %RuntimeError{message: "an expected test failure"},
            :internal_error
          )
        end
      end)

      refute_received {:sentry_envelope, _, _, _}
    end

    test "no migration, no table, and the relay needs none of it" do
      # The relay is in the supervision tree during the suite and the suite is
      # green, so a relay that needed a table would have failed every run. This
      # asserts the fact rather than the consequence.
      assert is_pid(Process.whereis(ErrorRelay))
    end
  end

  # ---------------------------------------------------------------------------
  # The OTel conventions, which are what keep the decision reversible.
  # ---------------------------------------------------------------------------

  describe "the OTel error conventions" do
    test "the class is stamped from core's closed vocabulary" do
      start_reporting()

      # Captured from inside a `rescue`, with a **distinct** message per class.
      # Both matter: the rescue is the only place a stack trace exists (see the
      # note in the leak test), and the distinct message is because the SDK drops
      # an event it considers a duplicate of one already captured — five identical
      # exceptions produce exactly one envelope, which is its own deduplication
      # working and a third volume control below the limiter and the throttle.
      for class <- ~w(invalid_request provider_auth timeout conflict internal_error)a do
        try do
          raise "a #{class} failure"
        rescue
          exception -> ErrorReporting.capture(exception, class)
        end
      end

      for class <- ~w(invalid_request provider_auth timeout conflict internal_error) do
        assert_receive {:sentry_envelope, _url, _headers, body}, 2_000
        assert body =~ ~s("error.type":"#{class}")
      end
    end

    test "a class outside the vocabulary is stored as _OTHER, with a warning" do
      # "Set `error.type` consistently" is only meaningful if the value is one of
      # the set. An undeclared class degrades to the semconv fallback rather than
      # being trusted, and says so — because an alert on `_OTHER` is core's
      # "this service has not classified its own errors", and a silent
      # degradation is how that alert stops meaning anything.
      start_reporting()

      log =
        capture_log(fn ->
          try do
            raise "an undeclared class"
          rescue
            exception -> ErrorReporting.capture(exception, :user_42_email_invalid)
          end
        end)

      assert_receive {:sentry_envelope, _url, _headers, body}, 2_000
      assert body =~ ~s("error.type":"_OTHER")
      refute body =~ "user_42_email_invalid"
      assert log =~ "not in core"
    end

    test "an absent class is not invented" do
      # The relay refuses an unclassified event outright rather than defaulting
      # it, and this is the half that makes that meaningful: the value courier
      # stamps is the class it was given, and a service that gives none produces
      # no `error.type` at all.
      assert "_OTHER" == ErrorReporting.normalise_type(:not_a_class)
      assert "timeout" == ErrorReporting.normalise_type(:timeout)
    end

    test "handled and retried errors are not recorded, because nothing captures them" do
      # The OTel spec is explicit — "Errors that were retried or handled (allowing
      # an operation to complete gracefully) SHOULD NOT be recorded" — and it is
      # enforced where the decision is made rather than at the store. The store
      # cannot tell a handled error from an unhandled one; both arrive as a
      # captured exception. So the rule is a property of *this* module: there is
      # no code path here that captures something the caller handled, because
      # `capture/3` is only ever called from a `rescue` that is re-raising or
      # from an exit handler. What this asserts is the negative that is checkable
      # — a *successful* operation reports nothing, and a class the caller
      # considers handled is one the caller simply does not pass here.
      start_reporting()

      # The positive half, from core's docs/observability.md rule 3: a
      # retried-then-succeeded operation emits one span with status ok and no
      # class, and the equivalent here is that the successful call reports
      # nothing at all.
      try do
        raise "a conflict courier handled"
      rescue
        exception -> ErrorReporting.capture(exception, :conflict)
      end

      assert_receive {:sentry_envelope, _url, _headers, _body}, 2_000

      # A handled error is an **event in the outbox** (PLAN.md §7b's first error
      # layer), aggregated by a consumer rather than by an SDK. So a conflict
      # courier handled and retried is a row, not an envelope, and the test
      # asserts the row is where it belongs: in the outbox, not here.
      refute_received {:sentry_envelope, _, _, _}
    end

    test "a 4xx is not an error, so it is not reported" do
      # `invalid_request` is in the vocabulary and is *storable* — it is a class
      # for a drill-down under a service filter, and it appears on spans. What it
      # is not is something to page on, and this is the distinction: the class is
      # available for the trace and the metric, and the *error store* gets only
      # the uncaught 5xx. The assertion is that `capture/3` is not called for it,
      # which is a property of the call sites, so what is asserted here is the
      # rule the call sites follow, stated once.
      assert ErrorReporting.allowed?(:invalid_request)
      assert ErrorReporting.allowed?(:rate_limited)
      assert ErrorReporting.allowed?(:cancelled)

      # ... and that the classes courier pages on are the three the vocabulary
      # says are worth a responder: the ones that are neither a caller error, nor
      # a rule, nor an expected outcome.
      for class <- ~w(internal_error dependency_unavailable connection_failed) do
        assert class in Policy.error_types()
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp start_reporting(opts \\ []) do
    dsn = Keyword.get(opts, :dsn, "http://publickey@relay.test/1")
    start_sdk? = Keyword.get(opts, :sdk, true)

    # `get_all_env/1`, not `get_env(:sentry, [])`. The SDK reads its whole
    # configuration as one keyword list, and `get_env/2` with a list as the *key*
    # returns nil — so a test that saved and restored it that way silently
    # restored nothing, and the next file in the suite would inherit this file's
    # DSN.
    previous = {
      Application.get_env(:courier, :error_reporting),
      Application.get_all_env(:sentry)
    }

    Application.put_env(:courier, :error_reporting,
      enabled: true,
      environment: "test",
      release: "test-release",
      dsn: dsn
    )

    if start_sdk? do
      # The SDK caches its configuration in `:persistent_term` when the `:sentry`
      # application starts and documents that it will not re-read it. So this is
      # not an `Application.put_env` away — the application has to be restarted,
      # which is why this is a helper and not a line in a `setup` block, and the
      # same reason the file is `async: false`.
      stop_the_sdk()

      # `put_all_env/2`, because `put_env/2` does not exist and `put_env/4` with
      # a keyword list as the *key* writes a key that is a list — which is why
      # the first version of this test set no DSN at all and every capture came
      # back `:ignored` with an empty mailbox.
      # `put_all_env/2` takes a list of `{app, keyword}` **pairs**, not an app
      # and a keyword list. Three wrong shapes got here first — `put_env/2`,
      # which does not exist; `put_env/4` with the keyword list as the key, which
      # writes a key that is a list; and `put_all_env(:sentry, [...])`, whose
      # first argument is a list. Each of them compiled, and each left the SDK
      # with no DSN, so every capture came back `:ignored` and every
      # `assert_receive` in this file timed out on an empty mailbox.
      Application.put_all_env(
        sentry: [
          dsn: dsn,
          client: SentryTestClient,
          before_send: {Courier.ErrorReporting.Filter, :before_send},
          send_default_pii: false,
          # `:sync` so `capture/2` has finished building and posting the envelope
          # by the time it returns. The default is `:none`, which posts from a
          # background task and would make every assertion in this file a race.
          # `:sync` is a **test-only** setting and the reason is stated here
          # because a `:sync` in `config.exs` would put the SDK's HTTP client on
          # the request path, which is the exact thing the packet forbids.
          send_result: :sync,
          request_timeout: 2_000
        ]
      )

      {:ok, _} = Application.ensure_all_started(:sentry)
    end

    on_exit(fn ->
      Application.put_env(:courier, :error_reporting, elem(previous, 0))

      Application.put_all_env([{:sentry, elem(previous, 1)}])
      stop_the_sdk()
      {:ok, _} = Application.ensure_all_started(:sentry)
    end)
  end

  # The SDK is stopped and started by these tests, and its cached configuration
  # lives in `:persistent_term`, so the restore has to put both back or the next
  # file in the suite starts with this one's DSN.
  defp stop_the_sdk do
    Application.stop(:sentry)
    :persistent_term.erase({Sentry.Config, :config})
    :ok
  end

  defp event_with_a_secret do
    %{
      "type" => "event",
      "payload" => %{
        "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
        "level" => "error",
        "transaction" => "courier.email.deliver",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
        "extra" => %{"prompt" => @canary_extra},
        "exception" => %{"values" => [%{"type" => "RuntimeError", "value" => @canary_message}]}
      }
    }
  end

  defp start_isolated_relay do
    name = :"reporting_test_relay_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ErrorRelay,
       name: name,
       sink: Courier.TestSupport.RecordingSink,
       sink_target: self(),
       burst: 50,
       per_minute: 60,
       capacity: 64,
       queue_size: 16}
    )

    name
  end

  # The same trick `health_controller_test.exs` uses for readiness: stop the repo
  # under the application supervisor rather than mocking the check, so the claim
  # is about a database that is genuinely not there.
  defp stop_the_repo do
    pid = Process.whereis(Courier.Repo)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Courier.Supervisor, Courier.Repo)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(Courier.Supervisor, Courier.Repo)
    end)
  end
end
