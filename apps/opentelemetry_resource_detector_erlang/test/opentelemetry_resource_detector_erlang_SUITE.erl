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
-module(opentelemetry_resource_detector_erlang_SUITE).

-compile(export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [merges_all_detectors, get_resource_callback_returns_same_attributes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% @doc The facade merges all three detectors; key attributes from each detector
%% should be present in the merged resource.
merges_all_detectors(_Config) ->
    Resource = opentelemetry_resource_detector_erlang:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    %% From beam_runtime_detector
    ?assert(maps:is_key('process.runtime.name', AttrMap)),
    RuntimeName = maps:get('process.runtime.name', AttrMap),
    ?assertEqual(<<"BEAM">>, RuntimeName),
    %% From host_detector
    ?assert(maps:is_key('host.name', AttrMap)),
    HostName = maps:get('host.name', AttrMap),
    ?assert(is_binary(HostName)),
    ?assert(byte_size(HostName) > 0),
    ?assert(maps:is_key('host.arch', AttrMap)),
    HostArch = maps:get('host.arch', AttrMap),
    ?assert(is_binary(HostArch)),
    ?assert(byte_size(HostArch) > 0).

%% @doc get_resource/1 is the otel_resource_detector behaviour callback; it
%% must produce the same attribute set as the direct detect/0 entry.
get_resource_callback_returns_same_attributes(_Config) ->
    Direct = otel_attributes:map(
        otel_resource:attributes(opentelemetry_resource_detector_erlang:detect())
    ),
    ViaCallback = otel_attributes:map(
        otel_resource:attributes(opentelemetry_resource_detector_erlang:get_resource(undefined))
    ),
    ?assertEqual(maps:keys(Direct), maps:keys(ViaCallback)),
    %% Spot-check a couple of values for identity.
    ?assertEqual(maps:get('process.runtime.name', Direct), maps:get('process.runtime.name', ViaCallback)),
    ?assertEqual(maps:get('host.name', Direct), maps:get('host.name', ViaCallback)).
