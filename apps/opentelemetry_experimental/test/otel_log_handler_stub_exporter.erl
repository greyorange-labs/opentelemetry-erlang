%%%-------------------------------------------------------------------
%%% @doc
%%% Test stub OTLP logs exporter for otel_log_handler_SUITE.
%%%
%%% The export result is taken from the exporter config, so a test can
%%% force `ok' / `failed_retryable' / `failed_not_retryable':
%%%
%%%   {otel_log_handler_stub_exporter, #{result => failed_retryable}}
%%% @end
%%%-------------------------------------------------------------------
-module(otel_log_handler_stub_exporter).

-export([init/1, export/3, shutdown/1]).

init(Config) ->
    {ok, Config}.

export(_Logs, _Resource, #{result := Result}) ->
    Result;
export(_Logs, _Resource, _Config) ->
    ok.

shutdown(_Config) ->
    ok.
