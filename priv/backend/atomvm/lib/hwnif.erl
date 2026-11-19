%% Stubs of the NIFs in src/ehls_nif.c (the kernels of `mix ehls.compile --target cpu`).
-module(hwnif).
-export([info/1, init/1, init/2, run/4]).

%% Kernel number Kernel (hw_nif:kernel/1): {InBytes, OutBytes, Levels, StateBytes, MaxIn}, MaxIn the most bytes one run takes.
-spec info(Kernel :: non_neg_integer()) -> {pos_integer(), pos_integer(), non_neg_integer(), pos_integer(), pos_integer()}.
info(_Kernel) -> erlang:nif_error(undefined).

%% The initial state of the kernel, a binary.
-spec init(Kernel :: non_neg_integer()) -> binary().
init(_Kernel) -> erlang:nif_error(undefined).

%% The initial state with its state words set (unsigned integers up to 64 bits, in the order of the kernel's state; extra
%% words are an error, missing ones stay as the kernel's own).
-spec init(Kernel :: non_neg_integer(), Words :: [non_neg_integer()]) -> binary().
init(_Kernel, _Words) -> erlang:nif_error(undefined).

%% Runs whole packed elements through the kernel from State (levels: Levels integers, as the circuit
%% has them wired): {the output's bytes, the next State}. One call is not interrupted by the VM:
%% In is limited to EHLS_NIF_MAX_IN bytes (badarg beyond); EHLS.NIFRun cuts a longer one.
-spec run(Kernel :: non_neg_integer(), State :: binary(), In :: binary(), Levels :: [integer()]) -> {binary(), binary()}.
run(_Kernel, _State, _In, _Levels) -> erlang:nif_error(undefined).
