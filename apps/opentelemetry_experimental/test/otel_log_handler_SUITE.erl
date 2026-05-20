%%%-------------------------------------------------------------------
%%% @doc
%%% Tests for otel_log_handler state machine.
%%%
%%% Regression coverage for the "exporting wedge" bug: if the first
%%% scheduled export timer fires while the batch is empty, the handler
%%% used to stay in the `exporting' state forever — subsequent log
%%% events enqueued into the batch via cast but no timer ever re-armed
%%% to drain them.
%%% @end
%%%-------------------------------------------------------------------
-module(otel_log_handler_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [empty_first_window_does_not_wedge,
     populated_first_window_drains].

init_per_suite(Config) ->
    application:ensure_all_started(opentelemetry_exporter),
    application:ensure_all_started(opentelemetry_experimental),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

handler_config(Id) ->
    #{id => Id,
      module => otel_log_handler,
      level => info,
      formatter => {logger_formatter, #{}},
      %% Short interval so the test runs quickly.
      scheduled_delay_ms => 100,
      exporter => none}.

install(Id) ->
    Config = handler_config(Id),
    ok = logger:add_handler(Id, otel_log_handler, Config),
    Id.

remove(Id) ->
    _ = logger:remove_handler(Id),
    _ = supervisor:terminate_child(opentelemetry_experimental_sup, Id),
    _ = supervisor:delete_child(opentelemetry_experimental_sup, Id),
    ok.

reg_name(Id) ->
    list_to_atom(lists:concat([otel_log_handler, "_", Id])).

state(Id) ->
    sys:get_state(reg_name(Id)).

batch_size({_State, DataTuple}) ->
    %% #data{} record's 10th tuple element is `batch'.
    map_size(element(10, DataTuple)).

state_name({State, _}) ->
    State.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

empty_first_window_does_not_wedge(_Config) ->
    Id = wedge_test_1,
    install(Id),
    try
        %% Wait past the first scheduled export window with no logs.
        timer:sleep(300),
        %% Now emit a log. Before the fix, the handler was wedged in
        %% `exporting' — the cast enqueued into batch but no timer ever
        %% re-armed to export it.
        logger:log(info, "wedge probe", #{mfa => {?MODULE, test, 1}}),
        %% Give the handler at least one more export window.
        timer:sleep(300),
        S = state(Id),
        ?assertEqual(idle, state_name(S)),
        ?assertEqual(0, batch_size(S))
    after
        remove(Id)
    end.

populated_first_window_drains(_Config) ->
    Id = wedge_test_2,
    install(Id),
    try
        %% Emit a log before the first export window.
        logger:log(info, "early probe", #{mfa => {?MODULE, test, 1}}),
        timer:sleep(300),
        S = state(Id),
        ?assertEqual(idle, state_name(S)),
        ?assertEqual(0, batch_size(S))
    after
        remove(Id)
    end.
