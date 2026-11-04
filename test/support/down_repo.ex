defmodule OCSF.Ecto.DownRepo do
  @moduledoc false

  # A Repo whose `insert_all/3` raises, as a database that is down does.
  # Lets sink tests take the error path without a real outage.

  def in_transaction?, do: false

  def insert_all(_schema, _rows, _opts),
    do: raise(DBConnection.ConnectionError, "connection refused")
end

defmodule OCSF.Ecto.DropsMidBatchRepo do
  @moduledoc false

  # A Repo that refuses the batch as one bad row would, then goes down
  # while the sink retries its rows one at a time.

  def in_transaction?, do: false

  def insert_all(_schema, [_row], _opts),
    do: raise(DBConnection.ConnectionError, "connection refused")

  def insert_all(_schema, _rows, _opts),
    do: raise(Ecto.ChangeError, message: "value does not match type")
end
