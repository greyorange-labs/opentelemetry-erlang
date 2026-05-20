%%%-------------------------------------------------------------------
%%% @doc
%%% Tests for otel_otlp_logs body encoding.
%%%
%%% Regression coverage for the charlist-body bug: textual log messages
%%% must be encoded as OTLP `string_value`, not `array_value` of ints.
%%% @end
%%%-------------------------------------------------------------------
-module(otel_otlp_logs_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [body_is_string_value_for_format_args,
     body_is_string_value_for_string_chardata,
     body_is_string_value_for_binary,
     body_is_string_value_for_atom_report].

init_per_suite(Config) ->
    application:ensure_all_started(opentelemetry_exporter),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Build a logger:log_event() compatible map with the given msg.
log_event(Msg) ->
    #{level => info,
      msg => Msg,
      meta => #{time => erlang:system_time(microsecond)}}.

%% Run the encoder and extract the LogRecord body's any_value.
encode_body(Msg) ->
    Scope = opentelemetry:get_application_scope(?MODULE),
    Logs = #{Scope => [log_event(Msg)]},
    [#{log_records := [#{body := AnyValue}]}] =
        otel_otlp_logs:to_proto_by_instrumentation_scope(Logs, #{}),
    AnyValue.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

body_is_string_value_for_format_args(_Config) ->
    %% {Format, Args} variant — the common ?INFO("...~p...", [X]) shape.
    AnyValue = encode_body({"hello ~p world", [42]}),
    ?assertMatch(#{value := {string_value, _}}, AnyValue),
    #{value := {string_value, Bin}} = AnyValue,
    ?assert(is_binary(Bin)),
    ?assertEqual(<<"hello 42 world">>, Bin).

body_is_string_value_for_string_chardata(_Config) ->
    %% {string, IoData} variant — chardata as a deep iolist.
    AnyValue = encode_body({string, ["he", <<"llo">>, " world"]}),
    ?assertMatch(#{value := {string_value, _}}, AnyValue),
    #{value := {string_value, Bin}} = AnyValue,
    ?assert(is_binary(Bin)),
    ?assertEqual(<<"hello world">>, Bin).

body_is_string_value_for_binary(_Config) ->
    %% {string, Binary} fast-path.
    AnyValue = encode_body({string, <<"plain binary">>}),
    ?assertMatch(#{value := {string_value, _}}, AnyValue),
    #{value := {string_value, Bin}} = AnyValue,
    ?assert(is_binary(Bin)),
    ?assertEqual(<<"plain binary">>, Bin).

body_is_string_value_for_atom_report(_Config) ->
    %% {report, Map} with no report_cb in meta — encoder formats the
    %% map via the standard format path. Result should still be a
    %% string_value binary, not array_value of ints.
    AnyValue = encode_body({"order=~p status=~p", [42, completed]}),
    ?assertMatch(#{value := {string_value, _}}, AnyValue),
    #{value := {string_value, Bin}} = AnyValue,
    ?assert(is_binary(Bin)).
