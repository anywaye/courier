defmodule Courier.StartupNoticesTest do
  @moduledoc """
  `Courier.StartupNotices` replays the operator-facing notices
  `config/runtime.exs` composes, at the level each was composed with.


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
    Application.put_env(:courier, :startup_notices, [{:warning, "sentinel: boot notice"}])

    log = capture_log(fn -> Courier.Application.start(:normal, []) end)

    assert log =~ "sentinel: boot notice",
           "Courier.Application.start/2 did not replay the composed notices. " <>
             "Wiring the emitter into the application's start is the whole " <>
             "mechanism — without it the notices are composed and dropped, which " <>
             "is the defect this module exists on the far side of.\n#{log}"
  end
end
