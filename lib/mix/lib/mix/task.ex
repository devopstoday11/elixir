defmodule Mix.Task do
  use Behaviour

  @moduledoc """
  A simple module that provides conveniences for creating,
  loading and manipulating tasks.

  A Mix task can be defined by simply using `Mix.Task`
  in a module starting with `Mix.Tasks.` and defining
  the `run/1` function:

      defmodule Mix.Tasks.Hello do
        use Mix.Task

        def run(_) do
          IO.puts "hello"
        end
      end

  The `run/1` function will receive all arguments passed
  to the command line.

  ## Attributes

  There are a couple attributes available in Mix tasks to
  configure them in Mix:

    * `@shortdoc`  - makes the task public with a short description that appears
                     on `mix help`
    * `@recursive` - run the task recursively in umbrella projects

  """

  @type task_name :: String.t | atom
  @type task_module :: atom

  @doc """
  A task needs to implement `run` which receives
  a list of command line args.
  """
  defcallback run([binary]) :: any

  @doc false
  defmacro __using__(_opts) do
    quote do
      Enum.each [:shortdoc, :recursive],
        &Module.register_attribute(__MODULE__, &1, persist: true)
      @behaviour Mix.Task
    end
  end

  @doc """
  Loads all tasks in all code paths.
  """
  @spec load_all() :: [task_module]
  def load_all, do: load_tasks(:code.get_path)

  @doc """
  Loads all tasks in the given `paths`.
  """
  @spec load_tasks([List.Chars.t]) :: [task_module]
  def load_tasks(dirs) do
    for dir <- dirs,
        {:ok, files} = :erl_prim_loader.list_dir(to_char_list(dir)),
        file <- files,
        mod = task_from_path(file),
        do: mod
  end

  @prefix_size byte_size("Elixir.Mix.Tasks.")
  @suffix_size byte_size(".beam")

  defp task_from_path(filename) do
    base = Path.basename(filename)
    part = byte_size(base) - @prefix_size - @suffix_size

    case base do
      <<"Elixir.Mix.Tasks.", rest :: binary-size(part), ".beam">> ->
        mod = :"Elixir.Mix.Tasks.#{rest}"
        ensure_task?(mod) && mod
      _ ->
        nil
    end
  end

  @doc """
  Returns all loaded task modules.

  Modules that are not yet loaded won't show up.
  Check `load_all/0` if you want to preload all tasks.
  """
  @spec all_modules() :: [task_module]
  def all_modules do
    for {module, _} <- :code.all_loaded,
        task?(module),
        do: module
  end

  @doc """
  Gets the moduledoc for the given task `module`.

  Returns the moduledoc or `nil`.
  """
  @spec moduledoc(task_module) :: String.t | nil
  def moduledoc(module) when is_atom(module) do
    case Code.get_docs(module, :moduledoc) do
      {_line, moduledoc} -> moduledoc
      nil -> nil
    end
  end

  @doc """
  Gets the shortdoc for the given task `module`.

  Returns the shortdoc or `nil`.
  """
  @spec shortdoc(task_module) :: String.t | nil
  def shortdoc(module) when is_atom(module) do
    case List.keyfind module.__info__(:attributes), :shortdoc, 0 do
      {:shortdoc, [shortdoc]} -> shortdoc
      _ -> nil
    end
  end

  @doc """
  Checks if the task should be run recursively for all sub-apps in
  umbrella projects.

  Returns `true` or `false`.
  """
  @spec recursive(task_module) :: boolean
  def recursive(module) when is_atom(module) do
    case List.keyfind module.__info__(:attributes), :recursive, 0 do
      {:recursive, [setting]} -> setting
      _ -> false
    end
  end

  @doc """
  Returns the task name for the given `module`.
  """
  @spec task_name(task_module) :: task_name
  def task_name(module) when is_atom(module) do
    Mix.Utils.module_name_to_command(module, 2)
  end

  @doc """
  Receives a task name and returns `{:ok, module}` if a task is found.

  Otherwise returns `{:error, :invalid}` in case the module
  exists but it isn't a task or `{:error, :not_found}`.
  """
  @spec get(task_name) :: {:ok, task_module} | {:error, :invalid} | {:error, :not_found}

  def get(task) when is_binary(task) or is_atom(task) do
    case Mix.Utils.command_to_module(to_string(task), Mix.Tasks) do
      {:module, module} ->
        if task?(module), do: {:ok, module}, else: {:error, :invalid}
      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Receives a task name and retrieves the task module.

  ## Exceptions

    * `Mix.NoTaskError`      - raised if the task could not be found
    * `Mix.InvalidTaskError` - raised if the task is not a valid `Mix.Task`

  """
  @spec get!(task_name) :: task_module | no_return
  def get!(task) do
    case get(task) do
      {:ok, module} ->
        module
      {:error, :invalid} ->
        Mix.raise Mix.InvalidTaskError, task: task
      {:error, :not_found} ->
        Mix.raise Mix.NoTaskError, task: task
    end
  end

  @doc """
  Runs a `task` with the given `args`.

  If the task was not yet invoked, it runs the task and
  returns the result.

  If the task was already invoked, it does not run the task
  again and simply aborts with `:noop`.

  It may raise an exception if the task was not found
  or it is invalid. Check `get!/1` for more information.
  """
  @spec run(task_name, [any]) :: any
  def run(task, args \\ []) when is_binary(task) or is_atom(task) do
    task = to_string(task)

    if Mix.TasksServer.run_task(task, Mix.Project.get) do
      module = get!(task)

      recur module, fn proj ->
        Mix.TasksServer.put_task(task, proj)
        module.run(args)
      end
    else
      :noop
    end
  end

  @doc """
  Clears all invoked tasks, allowing them to be reinvoked.
  """
  @spec clear :: :ok
  def clear do
    Mix.TasksServer.clear_tasks
  end

  @doc """
  Reenables a given task so it can be executed again down the stack.

  If an umbrella project reenables a task it is reenabled for all sub projects.
  """
  @spec reenable(task_name) :: :ok
  def reenable(task) when is_binary(task) or is_atom(task) do
    task   = to_string(task)
    module = get!(task)

    Mix.TasksServer.delete_task(task, Mix.Project.get)

    recur module, fn project ->
      Mix.TasksServer.delete_task(task, project)
    end

    :ok
  end

  defp recur(module, fun) do
    umbrella? = Mix.Project.umbrella?
    recursive = recursive(module)

    if umbrella? && recursive && Mix.ProjectStack.enable_recursion do
      # Get all dependency configuration but not the deps path
      # as we leave the control of the deps path still to the
      # umbrella child.
      config = Mix.Project.deps_config |> Keyword.delete(:deps_path)
      res = for %Mix.Dep{app: app, opts: opts} <- Mix.Dep.Umbrella.loaded do
        Mix.Project.in_project(app, opts[:path], config, fun)
      end
      Mix.ProjectStack.disable_recursion
      res
    else
      fun.(Mix.Project.get)
    end
  end

  @doc """
  Returns `true` if given module is a task.
  """
  @spec task?(task_module) :: boolean()
  def task?(module) when is_atom(module) do
    match?('Elixir.Mix.Tasks.' ++ _, Atom.to_char_list(module)) and ensure_task?(module)
  end

  defp ensure_task?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :run, 1)
  end
end
