defmodule Flurry.Mail do
  import Ecto.Query

  alias Flurry.{Error, Repo}
  alias Flurry.Schema.MailDelivery

  def enqueue(user, kind, subject, body) do
    delivery =
      %MailDelivery{}
      |> Ecto.Changeset.change(
        id: Ecto.UUID.generate(),
        user_id: user.id,
        recipient: user.email,
        kind: kind,
        subject: header!(subject),
        body: body,
        status: "queued",
        attempts: 0
      )
      |> Repo.insert!()

    deliver(delivery)
  end

  def deliver_pending(limit \\ 20) do
    Repo.all(
      from(m in MailDelivery,
        where: m.status in ["queued", "failed"] and m.attempts < 5,
        order_by: m.inserted_at,
        limit: ^limit
      )
    )
    |> Enum.each(&deliver/1)
  end

  def deliver(delivery) do
    case Application.get_env(:flurry, :mail) do
      %{url: _, api_key: _, from: _} = config -> api(delivery, config)
      nil -> local(delivery)
    end
  end

  def configured? do
    match?(%{url: _, api_key: _, from: _}, Application.get_env(:flurry, :mail)) or
      is_binary(Application.get_env(:flurry, :sendmail_path))
  end

  def public(delivery),
    do:
      Map.take(delivery, [
        :id,
        :recipient,
        :kind,
        :status,
        :attempts,
        :error,
        :delivered_at,
        :inserted_at
      ])

  defp sendmail(delivery, executable) do
    if Path.type(executable) == :absolute and File.regular?(executable) do
      sendmail_file(delivery, executable)
    else
      mark(delivery, "failed", "Configured mail-transfer executable is unavailable")
    end
  end

  defp local(delivery) do
    case Application.get_env(:flurry, :sendmail_path) do
      nil -> delivery
      executable -> sendmail(delivery, executable)
    end
  end

  defp api(delivery, config) do
    options = [
      url: config.url <> "/emails",
      auth: {:bearer, config.api_key},
      headers: [{"idempotency-key", delivery.id}],
      json: %{
        from: header!(config.from),
        to: [header!(delivery.recipient)],
        subject: header!(delivery.subject),
        text: delivery.body
      },
      redirect: false,
      retry: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000]
    ]

    options = Keyword.merge(options, Application.get_env(:flurry, :mail_req_options, []))

    case Req.post(options) do
      {:ok, %{status: status}} when status in 200..299 -> mark(delivery, "delivered", nil)
      _ -> mark(delivery, "failed", "Mail service rejected or could not accept the message")
    end
  end

  defp sendmail_file(delivery, executable) do
    message =
      [
        "To: ",
        header!(delivery.recipient),
        "\r\nFrom: Flurry <noreply@localhost>\r\nSubject: ",
        header!(delivery.subject),
        "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n",
        "Content-Transfer-Encoding: 8bit\r\n\r\n",
        delivery.body
      ]
      |> IO.iodata_to_binary()

    temporary = Path.join(System.tmp_dir!(), "flurry-mail-#{Ecto.UUID.generate()}")

    try do
      File.write!(temporary, message, [:binary, :exclusive])
      File.chmod!(temporary, 0o600)
      script = ~s(exec "$1" -t -i < "$2")

      case System.cmd("/bin/sh", ["-c", script, "flurry-mail", executable, temporary],
             stderr_to_stdout: true,
             env: [{"PATH", ""}]
           ) do
        {_, 0} -> mark(delivery, "delivered", nil)
        _ -> mark(delivery, "failed", "Local mail transfer rejected the message")
      end
    after
      File.rm(temporary)
    end
  end

  defp mark(delivery, status, error) do
    fields = [status: status, error: error, attempts: delivery.attempts + 1]

    fields =
      if status == "delivered",
        do: Keyword.put(fields, :delivered_at, DateTime.utc_now()),
        else: fields

    delivery |> Ecto.Changeset.change(fields) |> Repo.update!()
  end

  defp header!(value) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) <= 300 and
             not String.contains?(value, ["\r", "\n", <<0>>]),
           do: Error.fail("Invalid mail header", 500)

    value
  end
end
