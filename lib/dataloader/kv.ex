defmodule Dataloader.KV do
  require Logger

  @moduledoc """
  Simple KV based Dataloader source.

  This module is a simple key value based data loader source. You
  must supply a function that accepts ids, and returns a map of values
  keyed by id.

  ## Examples

  """

  defstruct [
    :load_function,
    opts: [],
    batches: %{},
    results: %{}
  ]

  def new(load_function, opts \\ []) do
    max_concurrency = opts[:max_concurrency] || System.schedulers_online() * 2

    %__MODULE__{
      load_function: load_function,
      opts: [
        max_concurrency: max_concurrency,
        timeout: opts[:timeout] || 30_000
      ]
    }
  end

  defimpl Dataloader.Source do
    defp merge_results(existing_results, new_results) do
      new_results
      |> Enum.reduce(existing_results, fn {batch_info, data}, acc ->
        case data do
          {:error, reason} ->
            merge_errors(acc, batch_info, reason)

          {:ok, data} ->
            merge(acc, Map.new([data]))
        end
      end)
    end

    defp merge_errors(acc, {batch_key, batch}, reason) do
      errors =
        batch
        |> Enum.reduce(%{}, fn key, acc ->
          Map.put(acc, key, {:error, reason})
        end)

      merge(acc, %{batch_key => errors})
    end

    defp merge(acc, results) do
      Map.merge(acc, results, fn _, v1, v2 ->
        Map.merge(v1, v2)
      end)
    end

    def put(source, _batch, _id, nil) do
      source
    end

    def put(source, batch, id, result) do
      results = Map.update(source.results, batch, %{id => result}, &Map.put(&1, id, result))
      %{source | results: results}
    end

    def load(source, _, nil) do
      source
    end

    def load(source, batch_key, id) do
      case fetch(source, batch_key, id) do
        {:error, _message} ->
          update_in(source.batches, fn batches ->
            Map.update(batches, batch_key, MapSet.new([id]), &MapSet.put(&1, id))
          end)

        _ ->
          source
      end
    end

    def load_many(source, _, ids) when ids in [nil, []] do
      source
    end

    def load_many(source, batch_key, ids) do
      with {:ok, batch} <- Map.fetch(source.results, batch_key) do
        existing =
          batch
          |> Map.take(ids)
          |> Map.keys()
          |> MapSet.new()

        idms = MapSet.new(ids)
        to_load = MapSet.difference(idms, existing)

        if MapSet.size(to_load) == 0 do
          source
        else
          update_in(source.batches, fn batches ->
            Map.update(batches, batch_key, to_load, &MapSet.union(&1, to_load))
          end)
        end
      else
        _ ->
          update_in(source.batches, fn batches ->
            ms = MapSet.new(ids)
            Map.update(batches, batch_key, ms, &MapSet.union(&1, ms))
          end)
      end
    end

    def fetch_many(source, batch_key, ids) do
      do_fetch_many(source, batch_key, ids)
    end

    def fetch(source, batch_key, id) do
      with {:ok, batch} <- Map.fetch(source.results, batch_key) do
        case Map.fetch(batch, id) do
          :error -> {:error, :not_found}
          {:ok, {:error, reason}} -> {:error, reason}
          {:ok, item} -> {:ok, item}
        end
      else
        :error ->
          {:error, "Unable to find batch #{inspect(batch_key)}"}
      end
    end

    def run(source) do
      fun = fn {batch_key, ids} ->
        {batch_key, source.load_function.(batch_key, ids)}
      end

      task_opts = Keyword.take(source.opts, [:timeout, :max_concurrency])

      results = Dataloader.async_safely(Dataloader, :run_tasks, [source.batches, fun, task_opts])

      %{source | batches: %{}, results: merge_results(source.results, results)}
    end

    def pending_batches?(source) do
      source.batches != %{}
    end

    def timeout(%{opts: opts}) do
      opts[:timeout]
    end

    defp do_fetch_many(_, _, []), do: {:ok, []}

    defp do_fetch_many(source, batch_key, ids) do
      do_fetch_many(source, batch_key, ids, {:ok, []})
    end

    defp do_fetch_many(_, _, [], {:ok, results}), do: {:ok, Enum.reverse(results)}

    defp do_fetch_many(_, _, _, {:error, _} = err) do
      err
    end

    defp do_fetch_many(source, batch_key, [id | rest], {:ok, results}) do
      case fetch(source, batch_key, id) do
        {:error, _} = err ->
          err

        {:ok, item} ->
          do_fetch_many(source, batch_key, rest, {:ok, [item | results]})
      end
    end
  end
end
