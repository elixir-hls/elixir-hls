-module(ehls_nif_test).
-export([start/0]).

start() ->
    SK = 'NifKd.stream_kernel',
    HV = 'NifKd.halve',
    K = hw_nif:kernel(SK),
    {4, 4, 0, _, 16384} = hwnif:info(K),
    %% a function call: 0x00020001 -> a = 1, b = 2: a > b is false, a + b * 2 = 5
    [5] = 'Elixir.EHLS.NIFRun':call(SK, [16#00020001]),
    %% a list as the output, and a state: from state 0 the 1st gives nothing, the 2nd and 4th come out, halved
    [4, 8] = 'Elixir.EHLS.NIFRun':call(HV, [4, 8, 12, 16]),
    %% 3000 elements whole and in chunks of 1, 7, 256: the same bytes, the state carried
    Xs = [(I * 2654435761) band 16#FFFFFFFF || I <- lists:seq(1, 3000)],
    Bin = hwstream:pack(Xs, 32),
    St0 = 'Elixir.EHLS.NIFRun':init(SK),
    {Whole, _} = 'Elixir.EHLS.NIFRun':run(St0, Bin, [], 3000),
    {C1, _} = 'Elixir.EHLS.NIFRun':run(St0, Bin, [], 1),
    {C7, _} = 'Elixir.EHLS.NIFRun':run(St0, Bin, [], 7),
    {C256, _} = 'Elixir.EHLS.NIFRun':run(St0, Bin, [], 256),
    true = Whole =:= C1 andalso Whole =:= C7 andalso Whole =:= C256 andalso byte_size(Whole) =:= 12000,
    %% state across calls: halve in halves of the input gives what one call gives
    H0 = 'Elixir.EHLS.NIFRun':init(HV),
    HBin = hwstream:pack([4, 8, 12, 16, 20, 24], 16 * -1),
    {HAll, _} = 'Elixir.EHLS.NIFRun':run(H0, HBin, [], 100),
    {HOne, _} = 'Elixir.EHLS.NIFRun':run(H0, HBin, [], 1),
    true = HAll =:= HOne,
    [4, 8, 12] = hwstream:unpack(HAll, -16),
    %% one NIF call is limited: a longer input is badarg (the caller cuts it)
    {State, _} = {element(2, St0), ok},
    TooBig = hwstream:pack(lists:duplicate(5000, 1), 32),
    %% a chunk of 0 or beyond the limit is cut to fit
    {Fit0, _} = 'Elixir.EHLS.NIFRun':run(St0, TooBig, [], 0),
    {FitBig, _} = 'Elixir.EHLS.NIFRun':run(St0, TooBig, [], 1000000),
    true = Fit0 =:= FitBig andalso byte_size(FitBig) =:= 20000,
    badarg = try hwnif:run(K, State, TooBig, []) catch error:badarg -> badarg end,
    badarg = try hwnif:run(K, State, <<1, 2, 3>>, []) catch error:badarg -> badarg end,
    badarg = try hwnif:run(K, State, <<1, 2, 3, 4>>, [1]) catch error:badarg -> badarg end,
    %% the time per element on this host (not the board)
    Big = hwstream:pack(lists:sublist(Xs, 3000), 32),
    T0 = erlang:monotonic_time(millisecond),
    ok = repeat(Big, St0, 20),
    T1 = erlang:monotonic_time(millisecond),
    erlang:display({nif_ok, ms_for_60000_elements, T1 - T0}),
    %% a state started from given words: halve from state 1 gives the first
    H1 = 'Elixir.EHLS.NIFRun':init(HV, [1]),
    {H1Out, _} = 'Elixir.EHLS.NIFRun':run(H1, hwstream:pack([4, 8, 12, 16], -16), [], 100),
    [2, 6] = hwstream:unpack(H1Out, -16),
    badarg = try hwnif:init(element(1, H1), [1, 2]) catch error:badarg -> badarg end,
    ok = driver_test(SK),
    ok.

%% EHLS.CpuDriver between a fake FPGA and a collector: three batches of 5 words through stream_kernel,
%% each result the same as the kernel's from the same state
driver_test(SK) ->
    Me = self(),
    Fake = spawn(fun() -> fake_fpga(0) end),
    Spec = #{name => cut, cancel => fun() -> Me ! cancelled, ok end, kernels => [{SK, nil}], pre => cut__pre, post => cut__post,
             request => fun(N) -> Fake ! {request, N, self()}, ok end,
             send => fun(Bin) -> Me ! {sent, Bin}, self() ! {cut__post, cpu_in, sent}, ok end,
             opts => [{batch, 5}, {chunk, 2}]},
    Driver = 'Elixir.EHLS.CpuDriver':start(Spec),
    [B1, B2, B3] = [receive {sent, B} -> B after 2000 -> error(no_batch) end || _ <- [1, 2, 3]],
    %% what the driver tells of itself: three batches (a fourth is asked for ahead) of 5 words of 4 bytes
    #{batches := Batches, bytes_in := BytesIn, bytes_out := BytesOut} = 'Elixir.EHLS.CpuDriver':stats(Driver),
    true = Batches >= 3 andalso BytesIn =:= Batches * 20 andalso BytesOut =:= BytesIn,
    Driver ! cpu_stop,
    receive cancelled -> ok after 2000 -> error(no_cancel) end,
    Words = [(I * 7 + 1) || I <- lists:seq(0, 14)],
    St = 'Elixir.EHLS.NIFRun':init(SK),
    {Whole, _} = 'Elixir.EHLS.NIFRun':run(St, hwstream:pack(Words, 32), [], 15),
    Whole = <<B1/binary, B2/binary, B3/binary>>,
    %% two kernels in one driver: stream_kernel, then halve from state 1 (u32 out of the first is not s16: use two
    %% stream_kernels, whose types agree)
    flush(),
    Fake2 = spawn(fun() -> fake_fpga(0) end),
    Spec2 = Spec#{kernels => [{SK, nil}, {SK, nil}], request => fun(N) -> Fake2 ! {request, N, self()}, ok end},
    Driver2 = 'Elixir.EHLS.CpuDriver':start(Spec2),
    B21 = receive {sent, X} -> X after 2000 -> error(no_batch) end,
    Driver2 ! cpu_stop,
    St2 = 'Elixir.EHLS.NIFRun':init(SK),
    {Once, _} = 'Elixir.EHLS.NIFRun':run(St2, hwstream:pack(lists:sublist(Words, 5), 32), [], 5),
    {Twice, _} = 'Elixir.EHLS.NIFRun':run(St2, Once, [], 5),
    Twice = B21,
    %% a stop while the driver waits for the DMA to take its result (no :sent comes): it still stops, and cancels
    flush(),
    receive cancelled -> ok after 0 -> ok end,
    Fake3 = spawn(fun() -> fake_fpga(0) end),
    Stuck = Spec#{request => fun(N) -> Fake3 ! {request, N, self()}, ok end,
                  send => fun(Bin) -> Me ! {sent, Bin}, ok end},
    Driver3 = 'Elixir.EHLS.CpuDriver':start(Stuck),
    receive {sent, _} -> ok after 2000 -> error(no_batch) end,
    %% the source goes on and nothing is taken after the cut: three results held at most (two given, one waiting), the
    %% older ones dropped
    timer:sleep(200),
    #{held_max := 3, dropped := Dropped} = 'Elixir.EHLS.CpuDriver':stats(Driver3),
    true = Dropped > 0,
    Driver3 ! cpu_stop,
    receive cancelled -> ok after 2000 -> error(no_cancel_while_waiting) end,
    ok.

flush() ->
    receive {sent, _} -> flush() after 200 -> ok end.

fake_fpga(Next) ->
    receive
        {request, N, Driver} ->
            Words = [(I * 7 + 1) || I <- lists:seq(Next, Next + N - 1)],
            Driver ! {cut__pre, out, hwstream:pack(Words, 32)},
            fake_fpga(Next + N)
    end.

repeat(_, _, 0) -> ok;
repeat(Bin, St, N) ->
    {_, _} = 'Elixir.EHLS.NIFRun':run(St, Bin, [], 256),
    repeat(Bin, St, N - 1).
