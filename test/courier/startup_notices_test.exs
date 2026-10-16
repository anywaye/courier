defmodule Courier.StartupNoticesTest do
  @moduledoc """
  `Courier.StartupNotices` replays the operator-facing notices
  `config/runtime.exs` composes, at the level each was composed with.

  ## What this file CANNOT prove, and why it exists anyway

  The defect these notices fix is about WHEN the release's boot script evaluates
  `config/runtime.exs` relative to the `:logger` application: at that moment
  there is no logger handler, so a `Logger.*` call is dropped with no error.
  Measured on two live boxes, `kubectl logs | grep -c 'mailer:\\|inbound:'`
  answered `0` on a fresh install (32 lines) and `0` on a box up for days (544
  lines).

  A test cannot reproduce that ordering — `Config.Reader.read!/2`, and every
  `Logger.*` in the suite, run with the logger already up. That is exactly why
  the pre-fix assertions in `release_migrate_config_test.exs` were green over a
  release that logged nothing: they exercised the mechanism that does not run in
  a release. So this file proves the two things it honestly can:

    * the emitter's content and level under `capture_log/1`; and
    * that `Courier.Application.start/2` calls it — the wiring, which is the
      whole mechanism.

  The end-to-end proof is a real release boot and a `kubectl logs | grep`, which
  a person with a box runs; this file does not claim to be that.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # `Application.put_env/3` and `Logger.configure/1` change state the whole VM
  # shares, so this file is `async: false` under the AGENTS.md rule. It touches
  # no `Courier.Repo`, which is why the tier it belongs to is the no-database
  # one — a leak-check that needed a row would be one a database-less runner
  # silently skips.
  setup do
    previous_notices = Application.get_env(:courier, :startup_notices, :unset)
    previous_level = Logger.level()

    on_exit(fn ->
      case previous_notices do
        :unset -> Application.delete_env(:courier, :startup_notices)
        value -> Application.put_env(:courier, :startup_notices, value)
      end

      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "replays every notice, exactly once, at the level it carries" do
    Application.put_env(:courier, :startup_notices, [
      {:warning, "notice: the warning"},
      {:info, "notice: the info"}
    ])

    # The suite's baseline is `config :logger, level: :warning`, and
    # `capture_log/2` does NOT raise that threshold — it only sets the capture
    # level. So the `:info` notice needs the logger level opened for the length
    # of the capture. This file is `async: false`, so the window is ours.
    Logger.configure(level: :info)

    log = capture_log(fn -> Courier.StartupNotices.log_startup() end)

    assert log =~ "notice: the warning"
    assert log =~ "notice: the info"

    assert length(Regex.scan(~r/notice: the warning/, log)) == 1,
           "a notice was emitted more than once:\n#{log}"

    assert length(Regex.scan(~r/notice: the info/, log)) == 1,
           "a notice was emitted more than once:\n#{log}"
  end

  test "an empty list emits nothing" do
    Application.put_env(:courier, :startup_notices, [])

    assert capture_log(fn -> Courier.StartupNotices.log_startup() end) == ""
  end

  test "an absent key emits nothing — the state in test and dev" do
    Application.delete_env(:courier, :startup_notices)

    assert capture_log(fn -> Courier.StartupNotices.log_startup() end) == ""
  end

  test "Courier.Application.start/2 replays the notices — the wiring, behaviourally" do
    # A sentinel at `:warning`, so the assertion does not depend on the logger
    # level. `Courier.Application.start/2` is the release's entry point; calling
    # it here re-runs the adapter gate and the other startup lines, then tries to
    # start `Courier.Supervisor`, which this suite already runs — so it returns
    # `{:error, {:already_started, _}}` AFTER the notices are emitted. That window
    # is what this asserts in, and deleting the call from the application would
    # go red here rather than in a review.
    Application.put_env(:courier, :startup_notices, [{:warning, "sentinel: boot notice"}])

    log = capture_log(fn -> Courier.Application.start(:normal, []) end)

    assert log =~ "sentinel: boot notice",
           "Courier.Application.start/2 did not replay the composed notices. " <>
             "Wiring the emitter into the application's start is the whole " <>
             "mechanism — without it the notices are composed and dropped, which " <>
             "is the defect this module exists on the far side of.\n#{log}"
  end
end
