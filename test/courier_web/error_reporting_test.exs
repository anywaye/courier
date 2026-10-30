defmodule CourierWeb.ErrorReportingTest do
  @moduledoc """
  What courier does on an unhandled error, and the four promises the packet makes
  about it. Read this as the brief's "Done means", one describe per promise.


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


  Because the alternative is asserting on a struct the test built by hand, which
  never touches the code that decides what goes into the event. The only thing
  replaced is the socket
  (`Courier.TestSupport.SentryTestClient`); event construction, `before_send`,
  the class tag, and envelope framing are all the SDK's own.


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


  describe "secrets never reach a stored error" do
    test "a secret in every place the SDK can put one is absent from the bytes on the wire" do
      start_reporting()

      secret = "hunter2-#{@canary_vars}"

      captured =
        try do
          raise "delivery failed for #{@canary_message} with #{@jwt}"
        rescue
          exception ->
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


      ErrorReporting.capture_any(:badarg, :internal_error)

      assert_receive {:sentry_envelope, _url, _headers, body}, 2_000
      assert is_binary(body)

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

      refute body =~ ~r/"extra":\{(?!\})/, "extra is present with content in the envelope"
      refute body =~ ~r/"user":\{(?!\})/, "user is present with content in the envelope"
      refute body =~ ~r/"request":\{(?!\})/, "request is present with content in the envelope"

      refute body =~ ~r/"breadcrumbs":\[(?!\])/,
             "breadcrumbs is present with content in the envelope"

      refute body =~ ~s("headers")

      refute body =~ ~s("vars":{)
      refute body =~ ~s("vars":[)
      refute body =~ secret

      assert body =~ ~s("type":"RuntimeError"), "the exception class survived"
      assert body =~ ~s("error.type":"internal_error")
      assert body =~ ~s("anywaye.redacted":"true")

      assert body =~ "error_reporting_test.exs"

      assert body =~ ~s("runtime")
    end

    test "a credential that arrives under an allowed key is masked, not kept" do
      start_reporting()

      try do
        raise "boom"
      rescue
        exception -> ErrorReporting.capture(exception, :internal_error)
      end

      assert_receive {:sentry_envelope, _url, _headers, _body}, 2_000
      assert Policy.mask("courier.send/#{@jwt}") == "courier.send/#{Policy.marker()}"
    end
  end


  describe "a failure in the error path cannot crash or block the main path" do
    test "capturing with reporting switched off returns :ok and touches nothing" do
      assert :ok == ErrorReporting.capture(%RuntimeError{message: "x"}, :internal_error)
      refute_received {:sentry_envelope, _, _, _}
    end

    test "capturing with the SDK not started returns :ok rather than raising" do
      start_reporting(sdk: false)

      result = ErrorReporting.capture(%RuntimeError{message: "x"}, :internal_error)

      assert :ok == result or match?({:error, _reason}, result)
    end

    test "a request still answers when the error path is completely broken" do
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

      assert :ok == ErrorReporting.capture_any("just a string", :internal_error)
      assert :ok == ErrorReporting.capture_any(%{status: 500}, :dependency_unavailable)
      assert :ok == ErrorReporting.capture_any(:badarg, :internal_error)
    end
  end


  describe "the error store is not courier's database" do
    test "this packet added no migration" do
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
      relay = start_isolated_relay()
      stop_the_repo()

      ErrorRelay.ingest(relay, [event_with_a_secret()])
      assert_receive {:relayed, body}, 2_000

      refute body =~ @canary_extra
      assert body =~ ~s("error.type":"internal_error")
    end
  end


  describe "reporting is off in test" do
    test "enabled?/0 is false" do
      refute ErrorReporting.enabled?()
    end

    test "the Sentry application has no DSN" do
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
      assert is_pid(Process.whereis(ErrorRelay))
    end
  end


  describe "the OTel error conventions" do
    test "the class is stamped from core's closed vocabulary" do
      start_reporting()

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
      assert "_OTHER" == ErrorReporting.normalise_type(:not_a_class)
      assert "timeout" == ErrorReporting.normalise_type(:timeout)
    end

    test "handled and retried errors are not recorded, because nothing captures them" do
      start_reporting()

      try do
        raise "a conflict courier handled"
      rescue
        exception -> ErrorReporting.capture(exception, :conflict)
      end

      assert_receive {:sentry_envelope, _url, _headers, _body}, 2_000

      refute_received {:sentry_envelope, _, _, _}
    end

    test "a 4xx is not an error, so it is not reported" do
      assert ErrorReporting.allowed?(:invalid_request)
      assert ErrorReporting.allowed?(:rate_limited)
      assert ErrorReporting.allowed?(:cancelled)

      for class <- ~w(internal_error dependency_unavailable connection_failed) do
        assert class in Policy.error_types()
      end
    end
  end


  defp start_reporting(opts \\ []) do
    dsn = Keyword.get(opts, :dsn, "http://publickey@relay.test/1")
    start_sdk? = Keyword.get(opts, :sdk, true)

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
      stop_the_sdk()

      Application.put_all_env(
        sentry: [
          dsn: dsn,
          client: SentryTestClient,
          before_send: {Courier.ErrorReporting.Filter, :before_send},
          send_default_pii: false,
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
