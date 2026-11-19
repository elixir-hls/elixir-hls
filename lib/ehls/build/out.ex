defmodule EHLS.Build.Out do
  @moduledoc false
  # a command's output shown line by line as it comes: UTF-8 as it is, a byte that is not (a board's console after a
  # reset, a binary protocol on the same port) as U+FFFD, so the output never stops the task
  defstruct []

  defimpl Collectable do
    def into(out) do
      {out,
       fn
         out, {:cont, chunk} ->
           IO.write(String.replace_invalid(chunk))
           out

         out, _ ->
           out
       end}
    end
  end
end
