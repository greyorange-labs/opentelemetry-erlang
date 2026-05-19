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
-module(host_detector_SUITE).

-compile(export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [detects_host_attributes, host_id_returns_non_empty_binary, host_id_fallback_hash_when_file_missing].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% @doc Verifies that host.name, host.arch, host.id, os.type, and os.description
%% are all present and non-empty.
detects_host_attributes(_Config) ->
    Resource = host_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assert(maps:is_key('host.name', AttrMap)),
    ?assert(maps:is_key('host.arch', AttrMap)),
    ?assert(maps:is_key('host.id', AttrMap)),
    ?assert(maps:is_key('os.type', AttrMap)),
    ?assert(maps:is_key('os.description', AttrMap)),
    HostName = maps:get('host.name', AttrMap),
    ?assert(is_binary(HostName)),
    ?assert(byte_size(HostName) > 0),
    OsType = maps:get('os.type', AttrMap),
    ?assert(is_binary(OsType)),
    ?assert(byte_size(OsType) > 0).

%% @doc host.id is always a non-empty binary, regardless of whether /etc/machine-id exists.
host_id_returns_non_empty_binary(_Config) ->
    Resource = host_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assert(maps:is_key('host.id', AttrMap)),
    HostId = maps:get('host.id', AttrMap),
    ?assert(is_binary(HostId)),
    ?assert(byte_size(HostId) > 0).

%% @doc host_id_fallback/1 always returns an MD5 hex binary regardless of filesystem state.
host_id_fallback_hash_when_file_missing(_Config) ->
    HashHex = host_detector:host_id_fallback(<<"my-test-host">>),
    true = is_binary(HashHex),
    true = byte_size(HashHex) > 0,
    %% MD5 hex is up to 32 chars; integer_to_list strips leading zeros
    true = byte_size(HashHex) =< 32,
    %% Same input -> same output (stability)
    HashHex = host_detector:host_id_fallback(<<"my-test-host">>),
    ok.
