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
     populated_first_window_drains,
     config_subkey_settings_are_read,
     legacy_top_level_settings_still_read,
     config_subkey_takes_precedence_over_top_level,
     max_queue_size_enforced_drops_and_reports,
     on_event_reports_successful_export,
     on_event_metadata_carries_handler_id,
     export_retried_then_dropped_after_max_retries].

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

%% #data{} record element offsets (element(1) is the `data' tag):
%%   3 = exporter_config, 8 = scheduled_delay_ms.
-define(EXPORTER_CONFIG_ELEM, 3).
-define(SCHEDULED_DELAY_ELEM, 8).

config_subkey_settings_are_read(_Config) ->
    %% Handler-specific settings nested under the OTP-idiomatic `config'
    %% sub-map must be honoured. This is what lets a caller pass a handler
    %% config that satisfies logger:handler_config() (which models
    %% `config => term()' but not a top-level `exporter' key).
    Id = config_subkey_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                config => #{scheduled_delay_ms => 4242,
                            exporter => none}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        {_State, Data} = state(Id),
        ?assertEqual(4242, element(?SCHEDULED_DELAY_ELEM, Data)),
        ?assertEqual(none, element(?EXPORTER_CONFIG_ELEM, Data))
    after
        remove(Id)
    end.

legacy_top_level_settings_still_read(_Config) ->
    %% Backwards compat: settings at the top level of the handler config
    %% (the pre-existing layout) must still be honoured.
    Id = legacy_top_level_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                scheduled_delay_ms => 7373,
                exporter => none},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        {_State, Data} = state(Id),
        ?assertEqual(7373, element(?SCHEDULED_DELAY_ELEM, Data)),
        ?assertEqual(none, element(?EXPORTER_CONFIG_ELEM, Data))
    after
        remove(Id)
    end.

config_subkey_takes_precedence_over_top_level(_Config) ->
    %% When a setting is present in both places, the nested `config'
    %% sub-map wins.
    Id = precedence_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                scheduled_delay_ms => 1111,
                config => #{scheduled_delay_ms => 2222,
                            exporter => none}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        {_State, Data} = state(Id),
        ?assertEqual(2222, element(?SCHEDULED_DELAY_ELEM, Data))
    after
        remove(Id)
    end.

%% #data{} element offset for batch_count (appended after batch at 10).
-define(BATCH_COUNT_ELEM, 11).

max_queue_size_enforced_drops_and_reports(_Config) ->
    %% max_queue_size is a hard cap on buffered events; anything beyond it
    %% is dropped and reported via on_event (reason => queue_full).
    Id = max_queue_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                config => #{max_queue_size => 2,
                            %% large enough that no export fires mid-test
                            scheduled_delay_ms => 60000,
                            exporter => none,
                            on_event => collector(self())}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        [cast_log(Id) || _ <- lists:seq(1, 5)],
        S = state(Id),                       %% sync barrier: all casts handled
        ?assertEqual(2, element(?BATCH_COUNT_ELEM, element(2, S))),
        ?assertEqual(3, count_events(dropped))
    after
        remove(Id)
    end.

on_event_reports_successful_export(_Config) ->
    %% A successful batch export reports `exported' with the record count.
    Id = export_ok_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                config => #{scheduled_delay_ms => 100,
                            exporter => {otel_log_handler_stub_exporter, #{result => ok}},
                            on_event => collector(self())}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        [cast_log(Id) || _ <- lists:seq(1, 3)],
        _ = state(Id),                       %% ensure all 3 enqueued before window
        case recv_event(exported, 2000) of
            {exported, Measurements, _} ->
                ?assertEqual(3, maps:get(count, Measurements));
            timeout ->
                ct:fail(no_exported_event)
        end
    after
        remove(Id)
    end.

on_event_metadata_carries_handler_id(_Config) ->
    %% Every on_event Metadata must carry `handler => Id` so an embedder
    %% running one handler per app/signal can label metrics by it.
    Id = handler_id_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                config => #{scheduled_delay_ms => 100,
                            exporter => {otel_log_handler_stub_exporter, #{result => ok}},
                            on_event => collector(self())}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        cast_log(Id),
        _ = state(Id),
        case recv_event(exported, 2000) of
            {exported, _Measurements, Metadata} ->
                ?assertEqual(Id, maps:get(handler, Metadata));
            timeout ->
                ct:fail(no_exported_event)
        end
    after
        remove(Id)
    end.

export_retried_then_dropped_after_max_retries(_Config) ->
    %% A failed_retryable batch is retained and retried for max_export_retries
    %% scheduled windows, then dropped to stop head-of-line blocking.
    Id = retry_test,
    HConfig = #{id => Id,
                module => otel_log_handler,
                level => info,
                formatter => {logger_formatter, #{}},
                config => #{scheduled_delay_ms => 100,
                            max_export_retries => 2,
                            exporter => {otel_log_handler_stub_exporter, #{result => failed_retryable}},
                            on_event => collector(self())}},
    ok = logger:add_handler(Id, otel_log_handler, HConfig),
    try
        cast_log(Id),
        _ = state(Id),                       %% enqueued before first window
        {export_failed, _, M1} = recv_event(export_failed, 2000),
        ?assertEqual(1, maps:get(retry, M1)),
        {export_failed, _, M2} = recv_event(export_failed, 2000),
        ?assertEqual(2, maps:get(retry, M2)),
        {dropped, _, M3} = recv_event(dropped, 2000),
        ?assertEqual(export_retries_exhausted, maps:get(reason, M3)),
        ?assertEqual(0, element(?BATCH_COUNT_ELEM, element(2, state(Id))))
    after
        remove(Id)
    end.

%%--------------------------------------------------------------------
%% Helpers for the observability / queue / retry tests
%%--------------------------------------------------------------------

%% on_event callback that forwards every event to the given pid.
collector(Pid) ->
    fun(Event, Measurements, Metadata) ->
        Pid ! {otel_event, Event, Measurements, Metadata},
        ok
    end.

%% Enqueue one log event directly into the handler's gen_statem, bypassing
%% logger routing so the test controls exactly what this handler sees.
cast_log(Id) ->
    Scope = opentelemetry:instrumentation_scope(<<"test">>, <<>>, <<>>),
    Event = #{level => info, msg => {string, "x"}, meta => #{}},
    gen_statem:cast(reg_name(Id), {log, Scope, Event}).

%% Wait for the next on_event with the given tag, ignoring others.
recv_event(Tag, Timeout) ->
    receive
        {otel_event, Tag, Measurements, Metadata} -> {Tag, Measurements, Metadata};
        {otel_event, _, _, _} -> recv_event(Tag, Timeout)
    after Timeout -> timeout
    end.

%% Count already-delivered on_event messages with the given tag.
count_events(Tag) ->
    receive
        {otel_event, Tag, _, _} -> 1 + count_events(Tag);
        {otel_event, _, _, _} -> count_events(Tag)
    after 0 -> 0
    end.
