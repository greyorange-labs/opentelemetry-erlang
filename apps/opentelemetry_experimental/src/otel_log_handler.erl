%%%------------------------------------------------------------------------
%% Copyright 2022, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc An OTP `logger' handler that batches log events and exports them
%% over OTLP.
%%
%% == Configuration ==
%%
%% Handler-specific settings are read from the OTP-idiomatic `config'
%% sub-map first, falling back to the top level of the handler config for
%% backwards compatibility. Nesting under `config' lets callers pass a
%% handler config that satisfies `logger:handler_config()' (which models
%% `config => term()' but not these custom keys at the top level):
%%
%% ```
%% logger:add_handler(my_otel_logs, otel_log_handler,
%%                    #{level => info,
%%                      config => #{exporter           => {otel_exporter_logs_otlp, ExpOpts},
%%                                  max_queue_size      => 2048,
%%                                  scheduled_delay_ms  => 5000,
%%                                  max_export_retries  => 3,
%%                                  on_event            => fun my_metrics:on_otel_log_event/3}}).
%% '''
%%
%% Settings:
%% <ul>
%%   <li>`exporter' — `{Module, Config}' OTLP logs exporter (default grpc).</li>
%%   <li>`max_queue_size' — max log events buffered between exports; events
%%        beyond this are dropped (an `dropped' event is reported). Default 2048.
%%        `infinity' disables the bound.</li>
%%   <li>`scheduled_delay_ms' — export flush interval. Default 5000.</li>
%%   <li>`max_export_retries' — how many consecutive scheduled windows a
%%        `failed_retryable' batch is retained and retried before being
%%        dropped (bounds head-of-line blocking when the sink is down).
%%        Default 3.</li>
%%   <li>`on_event' — optional `fun((Event, Measurements, Metadata) -> any())'
%%        invoked for observability. See "Observability".</li>
%% </ul>
%%
%% == Observability (`on_event') ==
%%
%% The handler stays backend-agnostic: instead of depending on a metrics
%% library, it invokes the optional `on_event' callback so the embedding
%% application can translate events into its own counters (prometheus,
%% telemetry, OTel metrics, ...). Exceptions raised by the callback are
%% caught and ignored. Events:
%% <ul>
%%   <li>`exported' — a batch was shipped. `Measurements = #{count => N}',
%%        `Metadata = #{handler => Id}'. Sum of `count' = "logs actually shipped".</li>
%%   <li>`dropped' — events were discarded. `#{count => N}',
%%        `#{reason => queue_full | export_retries_exhausted, handler => Id}'.</li>
%%   <li>`export_failed' — an export attempt failed. `#{count => N}',
%%        `#{reason => retryable | not_retryable, ..., handler => Id}'.</li>
%% </ul>
%% Every event's `Metadata' carries `handler => Id' (the logger handler id),
%% so an embedder running one handler per app/signal can label metrics by it.
%%
%% == Per-application batch processors ==
%%
%% Each handler instance is its own `gen_statem' with its own batch, export
%% timer and exporter. To get per-application batching (separate buffers /
%% flush cadence / endpoints per app), install one handler instance per app
%% with a filter that admits only that app's events:
%%
%% ```
%% lists:foreach(
%%   fun(App) ->
%%       Id = list_to_atom("otel_logs_" ++ atom_to_list(App)),
%%       logger:add_handler(Id, otel_log_handler,
%%                          #{filter_default => stop,
%%                            filters => [{App, {fun my_filters:by_app/2, App}}],
%%                            config => #{exporter => Exporter}})
%%   end, [mhs, pick, put]).
%% '''
%%
%% @end
%%%-------------------------------------------------------------------------
-module(otel_log_handler).

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-export([start_link/2]).

-export([log/2,
         adding_handler/1,
         removing_handler/1,
         changing_config/3,
         filter_config/1,
         report_cb/1]).

-export([init/1,
         callback_mode/0,
         idle/3,
         exporting/3,
         handle_event/3]).

-type config() :: #{id => logger:handler_id(),
                    regname := atom(),
                    config => term(),
                    level => logger:level() | all | none,
                    module => module(),
                    filter_default => log | stop,
                    filters => [{logger:filter_id(), logger:filter()}],
                    formatter => {module(), logger:formatter_config()}}.

-define(DEFAULT_CALL_TIMEOUT, 5000).
-define(DEFAULT_MAX_QUEUE_SIZE, 2048).
-define(DEFAULT_SCHEDULED_DELAY_MS, timer:seconds(5)).
-define(DEFAULT_EXPORTER_TIMEOUT_MS, timer:minutes(5)).
-define(DEFAULT_MAX_EXPORT_RETRIES, 3).

-define(name_to_reg_name(Module, Id),
        list_to_atom(lists:concat([Module, "_", Id]))).

-record(data, {exporter             :: {module(), term()} | undefined,
               exporter_config      :: {module(), term()} | undefined,
               resource             :: otel_resource:t(),

               runner_pid           :: pid() | undefined,
               max_queue_size       :: integer() | infinity,
               exporting_timeout_ms :: integer(),
               scheduled_delay_ms   :: integer(),

               config :: #{},
               batch  :: #{opentelemetry:instrumentation_scope() => [logger:log_event()]},

               %% Fields below are appended (kept last) so existing positional
               %% access to earlier fields stays stable.
               batch_count        :: non_neg_integer(),
               on_event           :: fun((atom(), map(), map()) -> any()) | undefined,
               max_export_retries :: non_neg_integer(),
               export_retries     :: non_neg_integer(),
               handler_id         :: logger:handler_id() | undefined}).

start_link(RegName, Config) ->
    gen_statem:start_link({local, RegName}, ?MODULE, [RegName, Config], []).

-spec adding_handler(Config) -> {ok, Config} | {error, Reason} when
      Config :: config(),
      Reason :: term().
adding_handler(#{id := Id,
                 module := Module}=Config) ->
    RegName = ?name_to_reg_name(Module, Id),
    ChildSpec =
        #{id       => Id,
          start    => {?MODULE, start_link, [RegName, Config]},
          restart  => temporary,
          shutdown => 2000,
          type     => worker,
          modules  => [?MODULE]},
    case supervisor:start_child(opentelemetry_experimental_sup, ChildSpec) of
        {ok, _Pid} ->
            %% ok = logger_handler_watcher:register_handler(Name,Pid),
            %% OlpOpts = logger_olp:get_opts(Olp),
            {ok, Config#{regname => RegName}};
        {error, {Reason, Ch}} when is_tuple(Ch), element(1, Ch) == child ->
            {error, Reason};
        {error, _Reason}=Error ->
            Error
    end.

%%%-----------------------------------------------------------------
%%% Updating handler config
-spec changing_config(SetOrUpdate, OldConfig, NewConfig) ->
          {ok,Config} | {error,Reason} when
      SetOrUpdate :: set | update,
      OldConfig :: config(),
      NewConfig :: config(),
      Config :: config(),
      Reason :: term().
changing_config(SetOrUpdate, OldConfig, NewConfig=#{regname := Id}) ->
    gen_statem:call(Id, {changing_config, SetOrUpdate, OldConfig, NewConfig}).

%%%-----------------------------------------------------------------
%%% Handler being removed
-spec removing_handler(Config) -> ok when
      Config :: config().
removing_handler(Config=#{regname := Id}) ->
    gen_statem:call(Id, {removing_handler, Config}).

%%%-----------------------------------------------------------------
%%% Log a string or report
-spec log(LogEvent, Config) -> ok when
      LogEvent :: logger:log_event(),
      Config :: config().
log(LogEvent, _Config=#{regname := Id}) ->
    Scope = case LogEvent of
                #{meta := #{otel_scope := Scope0=#instrumentation_scope{}}} ->
                    Scope0;
                #{meta := #{mfa := {Module, _, _}}} ->
                    opentelemetry:get_application_scope(Module);
                _ ->
                    opentelemetry:instrumentation_scope(<<>>, <<>>, <<>>)
            end,

    gen_statem:cast(Id, {log, Scope, LogEvent}).

%%%-----------------------------------------------------------------
%%% Remove internal fields from configuration
-spec filter_config(Config) -> Config when
      Config :: config().
filter_config(Config=#{regname := Id}) ->
    gen_statem:call(Id, {filter_config, Config}).

init([_RegName, Config]) ->
    process_flag(trap_exit, true),

    Resource = otel_resource_detector:get_resource(),

    %% Handler-specific settings are read from the OTP-idiomatic `config`
    %% sub-map first, falling back to the top level of the handler config
    %% for backwards compatibility. Nesting under `config` lets callers
    %% pass a handler config that satisfies `logger:handler_config()`
    %% (which types `config => term()` but does not model these custom
    %% keys at the top level), so `logger:add_handler/3` type-checks
    %% cleanly. See setting/4.
    Settings = maps:get(config, Config, #{}),
    SizeLimit = setting(max_queue_size, Settings, Config, ?DEFAULT_MAX_QUEUE_SIZE),
    ExportingTimeout = setting(exporting_timeout_ms, Settings, Config, ?DEFAULT_EXPORTER_TIMEOUT_MS),
    ScheduledDelay = setting(scheduled_delay_ms, Settings, Config, ?DEFAULT_SCHEDULED_DELAY_MS),
    MaxExportRetries = setting(max_export_retries, Settings, Config, ?DEFAULT_MAX_EXPORT_RETRIES),
    OnEvent = setting(on_event, Settings, Config, undefined),

    ExporterConfig = setting(exporter, Settings, Config, {opentelemetry_exporter, #{protocol => grpc}}),

    {ok, idle, #data{exporter=undefined,
                     exporter_config=ExporterConfig,
                     resource=Resource,
                     config=Config,
                     %% max_queue_size is a plain log-event count. (It was
                     %% previously divided by wordsize, but that value was
                     %% never enforced; now that it is, the documented count
                     %% is used as-is.)
                     max_queue_size=SizeLimit,
                     exporting_timeout_ms=ExportingTimeout,
                     scheduled_delay_ms=ScheduledDelay,
                     batch=#{},
                     batch_count=0,
                     on_event=OnEvent,
                     max_export_retries=MaxExportRetries,
                     export_retries=0,
                     handler_id=maps:get(id, Config, undefined)}}.

%% Resolve a handler-specific setting. Precedence:
%%   1. the OTP-idiomatic `config` sub-map (preferred),
%%   2. the top level of the handler config (legacy / backwards compat),
%%   3. the supplied default.
-spec setting(atom(), map(), map(), term()) -> term().
setting(Key, Settings, Config, Default) ->
    case Settings of
        #{Key := Value} -> Value;
        _ -> maps:get(Key, Config, Default)
    end.

callback_mode() ->
    [state_functions, state_enter].

idle(enter, _OldState, Data=#data{exporter=undefined,
                                  exporter_config=ExporterConfig,
                                  scheduled_delay_ms=SendInterval}) ->
    Exporter = init_exporter(ExporterConfig),
    {keep_state, Data#data{exporter=Exporter},
     [{{timeout, export_logs}, SendInterval, export_logs}]};
idle(enter, _OldState, #data{scheduled_delay_ms=SendInterval}) ->
    {keep_state_and_data, [{{timeout, export_logs}, SendInterval, export_logs}]};
idle(_, export_logs, Data=#data{exporter=undefined,
                                 exporter_config=ExporterConfig}) ->
    Exporter = init_exporter(ExporterConfig),
    {next_state, exporting, Data#data{exporter=Exporter}, [{next_event, internal, export}]};
idle(_, export_logs, Data) ->
    {next_state, exporting, Data, [{next_event, internal, export}]};
idle(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

exporting({timeout, export_logs}, export_logs, _) ->
    {keep_state_and_data, [postpone]};
exporting(enter, _OldState, _Data) ->
    keep_state_and_data;
exporting(internal, export, Data=#data{exporter=Exporter,
                                       resource=Resource,
                                       config=Config,
                                       batch=Batch,
                                       batch_count=Count,
                                       on_event=OnEvent,
                                       export_retries=Retries,
                                       max_export_retries=MaxRetries,
                                       handler_id=HandlerId}) when map_size(Batch) =/= 0 ->
    case export(Exporter, Resource, Batch, Config) of
        ok ->
            notify(OnEvent, exported, #{count => Count}, #{handler => HandlerId}),
            {next_state, idle, Data#data{batch=#{}, batch_count=0, export_retries=0}};
        {failed, retryable} when Retries + 1 =< MaxRetries ->
            %% Keep the batch; the next scheduled window retries it. New
            %% events still enqueue (up to max_queue_size), so growth is
            %% bounded. export_retries counts windows, not the batch.
            notify(OnEvent, export_failed, #{count => Count},
                   #{reason => retryable, retry => Retries + 1, max_retries => MaxRetries, handler => HandlerId}),
            {next_state, idle, Data#data{export_retries=Retries + 1}};
        {failed, retryable} ->
            %% Retries exhausted — drop to stop head-of-line blocking.
            notify(OnEvent, dropped, #{count => Count}, #{reason => export_retries_exhausted, handler => HandlerId}),
            {next_state, idle, Data#data{batch=#{}, batch_count=0, export_retries=0}};
        {failed, not_retryable} ->
            notify(OnEvent, export_failed, #{count => Count}, #{reason => not_retryable, handler => HandlerId}),
            {next_state, idle, Data#data{batch=#{}, batch_count=0, export_retries=0}}
    end;
exporting(internal, export, Data) ->
    %% Batch was empty when the scheduled timer fired. Without this clause
    %% the state machine wedges in `exporting` forever — idle/enter is the
    %% only place that arms the export_logs timer, and exporting/enter does
    %% not re-arm it. Subsequent log events enqueue into the batch via
    %% handle_event(cast, {log, ...}) but never get drained. Returning to
    %% idle re-arms the timer for the next window.
    {next_state, idle, Data};
exporting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

handle_event({call, From}, {changing_config, _SetOrUpdate, _OldConfig, NewConfig}, Data) ->
    {keep_state, Data#data{config=NewConfig}, [{reply, From, NewConfig}]};
handle_event({call, From}, {removing_handler, Config}, _Data) ->
    %% TODO: flush
    {keep_state_and_data, [{reply, From, Config}]};
handle_event({call, From}, {filter_handler, Config}, Data) ->
    {keep_state, Data, [{reply, From, Config}]};
handle_event({call, From}, {filter_config, Config}, Data) ->
    {keep_state, Data, [{reply, From, Config}]};
handle_event({call, _From}, _Msg, _Data) ->
    keep_state_and_data;
handle_event(cast, {log, Scope, LogEvent}, Data=#data{batch=Logs,
                                                      batch_count=Count,
                                                      max_queue_size=Max,
                                                      on_event=OnEvent,
                                                      handler_id=HandlerId}) ->
    case Max =/= infinity andalso Count >= Max of
        true ->
            %% Queue full — drop the event rather than grow unbounded.
            notify(OnEvent, dropped, #{count => 1}, #{reason => queue_full, handler => HandlerId}),
            keep_state_and_data;
        false ->
            {keep_state, Data#data{batch=maps:update_with(Scope, fun(V) ->
                                                                         [LogEvent | V]
                                                                 end, [LogEvent], Logs),
                                   batch_count=Count + 1}}
    end;
handle_event(_, _, _) ->
    keep_state_and_data.

%%

init_exporter(ExporterConfig) ->
    case otel_exporter:init(ExporterConfig) of
        Exporter when Exporter =/= undefined andalso Exporter =/= none ->
            Exporter;
        _ ->
            undefined
    end.

%% Returns `ok' on success, or `{failed, retryable | not_retryable}'.
%% An exporter exception is treated as a non-retryable failure (and never
%% allowed to crash the handler).
-spec export({module(), term()} | undefined, otel_resource:t(), map(), map()) ->
          ok | {failed, retryable | not_retryable}.
export(undefined, _, _, _) ->
    ok;
export(Exporter, Resource, Batch, Config) ->
    try otel_exporter_logs:export(Exporter, {Batch, Config}, Resource) of
        failed_retryable -> {failed, retryable};
        failed_not_retryable -> {failed, not_retryable};
        _ -> ok
    catch
        Kind:Reason:StackTrace ->
            ?LOG_WARNING(#{source => exporter,
                           during => export,
                           kind => Kind,
                           reason => Reason,
                           exporter => Exporter,
                           stacktrace => StackTrace}, #{report_cb => fun ?MODULE:report_cb/1}),
            {failed, not_retryable}
    end.

%% Invoke the optional observability callback. Never lets a misbehaving
%% callback crash the handler.
-spec notify(fun((atom(), map(), map()) -> any()) | undefined, atom(), map(), map()) -> ok.
notify(OnEvent, Event, Measurements, Metadata) when is_function(OnEvent, 3) ->
    try
        _ = OnEvent(Event, Measurements, Metadata),
        ok
    catch
        _:_ -> ok
    end;
notify(_, _, _, _) ->
    ok.

%% logger format functions
report_cb(#{source := exporter,
            during := export,
            kind := Kind,
            reason := Reason,
            exporter := {ExporterModule, _},
            stacktrace := StackTrace}) ->
    {"log exporter threw exception: exporter=~p ~ts",
     [ExporterModule, otel_utils:format_exception(Kind, Reason, StackTrace)]}.
