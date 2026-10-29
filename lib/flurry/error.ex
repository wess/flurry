defmodule Flurry.Error do
  defexception [:message, status: 422, details: %{}]

  def fail(message, status \\ 422, details \\ %{}) do
    raise __MODULE__, message: message, status: status, details: details
  end
end
