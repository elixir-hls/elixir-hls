%% Stubs of the NIFs in src/hwstream_nif.c (the LiteX backend's hwstream CSRs and DMA).
-module(hwstream).
-export([pipe_enable/2, end_send/5, end_request/5, end_cancel/1, peek/2, mem_read/3, level_start/3, end_push/3, event_subscribe/7, event_unsubscribe/2, reg_read/1, reg_write/2,
         pack/2, unpack/2]).

%% Starts / stops instance number Pipeline (hw_kernels:pipeline/1), running from reset; a start
%% restarts the state of its stateful kernels, a stop drops what its CPU ends' links hold.
-spec pipe_enable(Pipeline :: non_neg_integer(), On :: boolean()) -> ok.
pipe_enable(_Pipeline, _On) -> erlang:nif_error(undefined).

%% Gives Input (packed elements, not empty) to CPU end number End (hw_kernels:cpu_end/2)
%% of instance Pipeline, without waiting: {Name, Tag, sent} comes to the caller when the DMA has read it.
-spec end_send(End :: non_neg_integer(), Pipeline :: non_neg_integer(), Name :: atom(), Tag :: atom(), Input :: binary()) -> ok | busy | stopped.
end_send(_End, _Pipeline, _Name, _Tag, _Input) -> erlang:nif_error(undefined).

%% Asks CPU end number End for its next Bytes (whole elements, not 0), without waiting: {Name, Tag,
%% Binary} comes to the caller when they have arrived.
-spec end_request(End :: non_neg_integer(), Pipeline :: non_neg_integer(), Name :: atom(), Tag :: atom(), Bytes :: pos_integer()) -> ok | busy | stopped.
end_request(_End, _Pipeline, _Name, _Tag, _Bytes) -> erlang:nif_error(undefined).

%% The elements of List in the packed format of a CPU end, each value wrapped to its type
%% (src/hwstream_pack.c; Layout as EHLS.layout/1 gives it: bits, negative when signed, tuples of those).
-spec pack(List :: list(), Layout :: integer() | tuple()) -> binary().
pack(_List, _Layout) -> erlang:nif_error(undefined).

%% The elements of a packed Binary: signed values negative, tuples as tuples; badarg if it is
%% not a whole number of elements.
-spec unpack(Binary :: binary(), Layout :: integer() | tuple()) -> list().
unpack(_Binary, _Layout) -> erlang:nif_error(undefined).

%% Cancels what is in flight on CPU end number End: no message follows.
-spec end_cancel(End :: non_neg_integer()) -> ok.
end_cancel(_End) -> erlang:nif_error(undefined).

%% The Words state words (32-bit unsigned values) of stage number Stage of a running pipeline
%% (hw_kernels:state/2, hold/2), taken at one clock so that they cannot tear.
-spec peek(Stage :: non_neg_integer(), Words :: pos_integer()) -> [non_neg_integer()].
peek(_Stage, _Words) -> erlang:nif_error(undefined).

%% Count words (32-bit unsigned) from Addr of the memory space of stage number Stage: a named
%% state's memories (hw_kernels:state/2), each as it is when read.
-spec mem_read(Stage :: non_neg_integer(), Addr :: non_neg_integer(), Count :: pos_integer()) -> [non_neg_integer()].
mem_read(_Stage, _Addr, _Count) -> erlang:nif_error(undefined).

%% Writes Words (32-bit words, low first) as the arguments of instance of levels number Level
%% (hw_kernels:level/1), then its start write, which takes them all at one clock and fires it:
%% the count of that start, which its result is held with (peek/2), or stopped when instance Pipeline is.
-spec level_start(Level :: non_neg_integer(), Pipeline :: non_neg_integer(), Words :: [integer()]) -> non_neg_integer() | stopped.
level_start(_Level, _Pipeline, _Words) -> erlang:nif_error(undefined).

%% One element given to input end End of instance Pipeline without DMA: its packed bytes as 32-bit words,
%% low first, into the end's small FIFO.
-spec end_push(End :: non_neg_integer(), Pipeline :: non_neg_integer(), Words :: [integer()]) -> ok | full | stopped.
end_push(_End, _Pipeline, _Words) -> erlang:nif_error(undefined).

%% Pid gets {Name, Value} for each event of topic number Topic (hw_kernels:topic/1), Value Bits wide,
%% signed if Signed; ok, or full with 4 subscribers already.
-spec event_subscribe(Topic :: non_neg_integer(), Name :: atom(), Bits :: pos_integer(), Signed :: boolean(), Pid :: pid(),
                      Active :: integer(), Stamps :: boolean()) -> ok | full.
event_subscribe(_Topic, _Name, _Bits, _Signed, _Pid, _Active, _Stamps) -> erlang:nif_error(undefined).

%% No more events of topic number Topic for Pid.
-spec event_unsubscribe(Topic :: non_neg_integer(), Pid :: pid()) -> ok.
event_unsubscribe(_Topic, _Pid) -> erlang:nif_error(undefined).

%% Reads register number Reg (hw_kernels:reg/2) of a block package.
-spec reg_read(Reg :: non_neg_integer()) -> non_neg_integer().
reg_read(_Reg) -> erlang:nif_error(undefined).

%% Writes Value (its low 32 bits) to register number Reg (hw_kernels:reg/2).
-spec reg_write(Reg :: non_neg_integer(), Value :: integer()) -> ok.
reg_write(_Reg, _Value) -> erlang:nif_error(undefined).
