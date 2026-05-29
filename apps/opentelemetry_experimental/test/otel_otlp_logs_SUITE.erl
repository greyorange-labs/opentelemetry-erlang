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
     body_is_string_value_for_atom_report,
     any_value_charlist_becomes_string,
     any_value_integer_array_stays_array,
     any_value_proplist_stays_kvlist,
     trace_context_hex_decoded_to_raw_bytes,
     trace_context_absent_when_no_span].

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

%%--------------------------------------------------------------------
%% to_any_value/1 regression tests
%%
%% Logger metadata commonly contains charlists (?FILE = "/path/foo.erl",
%% function names rendered via atom_to_list/1, etc). Prior to the fix
%% these encoded as OTLP array_value of int_value, which surfaced as
%% `[47, 85, 115, ...]` in Loki for the `file` attribute. The chardata
%% discriminator must convert charlists to string_value while leaving
%% non-textual lists (integer arrays, proplists) alone.
%%--------------------------------------------------------------------

any_value_charlist_becomes_string(_Config) ->
    %% Typical ?FILE — flat printable charlist.
    AnyValue = otel_otlp_common:to_any_value("/Users/amar/foo.erl"),
    ?assertMatch(#{value := {string_value, <<"/Users/amar/foo.erl">>}}, AnyValue).

any_value_integer_array_stays_array(_Config) ->
    %% Non-printable codepoints (1..8 are control chars) — must remain
    %% an integer array, not be misinterpreted as a 3-byte string.
    AnyValue = otel_otlp_common:to_any_value([1, 2, 3]),
    ?assertMatch(#{value := {array_value, _}}, AnyValue),
    #{value := {array_value, #{values := Values}}} = AnyValue,
    ?assertEqual([#{value => {int_value, 1}},
                  #{value => {int_value, 2}},
                  #{value => {int_value, 3}}], Values).

any_value_proplist_stays_kvlist(_Config) ->
    %% Proplist must still be encoded as kvlist_value — the chardata
    %% discriminator must not steal proplists.
    AnyValue = otel_otlp_common:to_any_value([{key1, <<"v1">>}, {key2, 42}]),
    ?assertMatch(#{value := {kvlist_value, _}}, AnyValue).

%% Build a LogRecord from a log event carrying the given extra metadata.
encode_record(ExtraMeta) ->
    Scope = opentelemetry:get_application_scope(?MODULE),
    Event = #{level => info,
              msg => {string, <<"trace ctx test">>},
              meta => maps:merge(#{time => erlang:system_time(microsecond)}, ExtraMeta)},
    [#{log_records := [Record]}] =
        otel_otlp_logs:to_proto_by_instrumentation_scope(#{Scope => [Event]}, #{}),
    Record.

trace_context_hex_decoded_to_raw_bytes(_Config) ->
    %% otel_span:hex_span_ctx/1 puts 32/16-char hex binaries into logger
    %% metadata. The OTLP LogRecord trace_id/span_id are protobuf `bytes`
    %% and must be the raw 16/8-byte values — emitting the hex form makes
    %% the batch export fail and silently drops every log in the flush.
    TraceHex = <<"ab6a43eb9e934a17038b0387e8d2683b">>,
    SpanHex  = <<"1d156c0509c82f12">>,
    Record = encode_record(#{otel_trace_id => TraceHex,
                             otel_span_id => SpanHex,
                             otel_trace_flags => <<"01">>}),
    #{trace_id := TraceId, span_id := SpanId, trace_flags := Flags} = Record,
    ?assertEqual(16, byte_size(TraceId)),
    ?assertEqual(8, byte_size(SpanId)),
    ?assertEqual(binary:decode_hex(TraceHex), TraceId),
    ?assertEqual(binary:decode_hex(SpanHex), SpanId),
    ?assertEqual(1, Flags).

trace_context_absent_when_no_span(_Config) ->
    %% No active span -> no otel_trace_id in metadata -> LogRecord carries
    %% no trace_id/span_id (and must still encode cleanly).
    Record = encode_record(#{}),
    ?assertEqual(error, maps:find(trace_id, Record)),
    ?assertEqual(error, maps:find(span_id, Record)).
