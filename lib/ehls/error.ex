defmodule EHLS.Error do
  @moduledoc false
  # What cannot be built, found while translating an application's source: `ArgumentError`s raised
  # anywhere under `compile/3` become a `CompileError` at the source line, the innermost `at/2` that
  # knows one, else the definition's.

  defexception [:message, :line]

  def at(line, fun) when is_integer(line) do
    try do
      fun.()
    rescue
      e in ArgumentError -> reraise %__MODULE__{message: Exception.message(e), line: line}, __STACKTRACE__
    end
  end

  def at(_no_line, fun), do: fun.()

  def compile(file, line, fun) do
    try do
      fun.()
    rescue
      e in __MODULE__ -> compile_error(file, e.line, e.message, __STACKTRACE__)
      e in ArgumentError -> compile_error(file, line, Exception.message(e), __STACKTRACE__)
    end
  end

  defp compile_error(file, line, message, stacktrace),
    do: reraise(CompileError, [file: Path.relative_to_cwd(file), line: line, description: message], stacktrace)
end
