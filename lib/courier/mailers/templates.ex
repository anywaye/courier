defmodule Courier.Mailers.Templates do
  @moduledoc """
  The mail bodies, compiled when courier is compiled.

  Compiling them here rather than reading them at runtime is what makes a
  release image work: `EEx.eval_file/3` would need the `.eex` files on disk, and
  Mix copies `lib/` into the beam, not loose templates beside it. It also means a
  template that does not parse fails `mix compile` rather than the first welcome
  mail somebody is waiting for.

  The `@external_resource` attributes are what make that true on a *rebuild*:
  without them Mix would not recompile this module when a template changed, and
  a fixed template would keep shipping the old body.
  """

  @root Path.expand("templates", __DIR__)

  @external_resource Path.join(@root, "layout.html.eex")
  @external_resource Path.join(@root, "layout.text.eex")
  @external_resource Path.join(@root, "welcome.html.eex")
  @external_resource Path.join(@root, "welcome.text.eex")
  @external_resource Path.join(@root, "password_reset.html.eex")
  @external_resource Path.join(@root, "password_reset.text.eex")
  @external_resource Path.join(@root, "team_invitation.html.eex")
  @external_resource Path.join(@root, "team_invitation.text.eex")
  @external_resource Path.join(@root, "account_security.html.eex")
  @external_resource Path.join(@root, "account_security.text.eex")
  @external_resource Path.join(@root, "email_change_current.html.eex")
  @external_resource Path.join(@root, "email_change_current.text.eex")
  @external_resource Path.join(@root, "email_change_new.html.eex")
  @external_resource Path.join(@root, "email_change_new.text.eex")

  @templates Map.new(Path.wildcard(Path.join(@root, "*.eex")), fn path ->
               {Path.basename(path, ".eex"), EEx.compile_file(path)}
             end)

  @doc """
  Every template this module has, by name — `"welcome.html"`, `"layout.text"`.
  """
  @spec names() :: [String.t()]
  def names, do: @templates |> Map.keys() |> Enum.sort()

  @doc """
  Renders the template `name` with `assigns`.

  `Code.eval_quoted/2` rather than `EEx.eval_file/3`: the template is already
  compiled into this module, so a send parses nothing. Elixir 1.20 has no
  public `EEx.eval_expr/2` — the compiled form is evaluated as quoted code, with
  the assigns bound under the name the template refers to.
  """
  @spec render(String.t(), keyword() | map()) :: String.t()
  def render(name, assigns) do
    @templates
    |> Map.fetch!(name)
    |> Code.eval_quoted(assigns: assigns)
    |> elem(0)
    |> IO.iodata_to_binary()
  end
end
