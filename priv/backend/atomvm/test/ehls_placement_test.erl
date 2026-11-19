%% Instances placed on the CPU (placement_demo.ex) in AtomVM: each check a match, a crash on the first wrong one.
-module(ehls_placement_test).
-export([start/0]).

-define(M, 'Elixir.PlacementDemo').

start() ->
    %% a list in, a list out; the state goes on across calls; :start starts again; :stop stops
    [4, 10] = ?M:summing([1, 2]),
    [18] = ?M:summing([3]),
    18 = ?M:summing(state, sum),
    ok = ?M:summing(start),
    [4] = ?M:summing([1]),
    ok = ?M:summing(stop),
    {error, stopped} = ?M:summing([1]),
    ok = ?M:summing(start),
    %% a binary in, a binary out (the packed format)
    <<4, 0, 0, 0, 10, 0, 0, 0>> = ?M:summing(<<1, 2>>),
    %% a join of two arguments
    [6, 12, -4] = ?M:mixer([2, 4, -6], [10, 20, -2]),
    %% a fork with a branch into a hold
    [1, 2, 3] = ?M:tapped([4, 6, 8]),
    7 = ?M:tapped(value, last),
    %% a source: from :start, the next n in order; a request sends them packed
    ok = ?M:counts(start),
    [0, 1, 2, 3, 4] = ?M:counts(out, 5, [{as, list}]),
    ok = ?M:counts(request, out, 2),
    receive {counts, out, <<5:32/little, 6:32/little>>} -> ok after 2000 -> error(no_request) end,
    %% more than the buffer holds: the timer waits, nothing lost
    timer:sleep(50),
    Seq = lists:seq(7, 46),
    Seq = ?M:counts(out, 40, [{as, list}]),
    %% a source into a hold
    0 = ?M:presses(value, n),
    ok = ?M:presses(start),
    timer:sleep(50),
    N = ?M:presses(value, n),
    true = N > 10,
    ok = ?M:presses(stop),
    %% an instance of levels, wired into a stage
    3 = ?M:gain(value),
    [3, 6] = ?M:scaled([1, 2]),
    10 = ?M:gain(10),
    [10, 20] = ?M:scaled([1, 2]),
    %% a generated kernel (chunk_every(2, 2, :discard) |> map): sums of 1+2 and 3+4
    [3, 7] = ?M:pairs([1, 2, 3, 4]),
    %% a negative initial state, a signed level
    [5, 0, 0] = ?M:negs([5, 6, 7]),
    [-99] = ?M:offs([1]),
    erlang:display({placement_ok, presses, N}),
    ok.
