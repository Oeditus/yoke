defmodule Yoke.Test.StubInteraction do
  @moduledoc """
  A deterministic `Yoke.Interaction` implementation for tests.

  It records every request it receives (in the calling process's mailbox as
  `{:stub_interaction, kind, context}`) and answers from the `:answer` key of
  the context, defaulting to `:deny`. Used to prove that the seam is actually
  consulted by the agent loop without involving a terminal.
  """

  @behaviour Yoke.Interaction

  @impl true
  def ask(kind, context) do
    send(self(), {:stub_interaction, kind, context})
    Map.get(context, :answer, :deny)
  end
end
