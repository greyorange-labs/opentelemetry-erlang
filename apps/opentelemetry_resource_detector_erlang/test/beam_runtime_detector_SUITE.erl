%%%------------------------------------------------------------------------
%% Copyright 2024, GreyOrange Authors
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
%%%------------------------------------------------------------------------
-module(beam_runtime_detector_SUITE).

-compile(export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [detects_process_runtime_attributes, detects_process_pid, returns_otel_resource].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% @doc Verifies that process.runtime.name, process.runtime.version, and
%% process.runtime.description are all present and non-empty.
detects_process_runtime_attributes(_Config) ->
    Resource = beam_runtime_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assertMatch(#{
        'process.runtime.name' := <<"BEAM">>,
        'process.runtime.version' := _,
        'process.runtime.description' := _
    }, AttrMap),
    Version = maps:get('process.runtime.version', AttrMap),
    ?assert(is_binary(Version)),
    ?assert(byte_size(Version) > 0),
    Desc = maps:get('process.runtime.description', AttrMap),
    ?assert(is_binary(Desc)),
    ?assert(byte_size(Desc) > 0).

%% @doc Verifies that process.pid is present and is a positive integer.
detects_process_pid(_Config) ->
    Resource = beam_runtime_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assert(maps:is_key('process.pid', AttrMap)),
    Pid = maps:get('process.pid', AttrMap),
    ?assert(is_integer(Pid)),
    ?assert(Pid > 0).

%% @doc Verifies that detect/0 returns a valid otel_resource:t().
returns_otel_resource(_Config) ->
    R = beam_runtime_detector:detect(),
    Map = otel_attributes:map(otel_resource:attributes(R)),
    ?assert(is_map(Map)).
