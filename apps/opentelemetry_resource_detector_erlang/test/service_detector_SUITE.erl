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
-module(service_detector_SUITE).

-compile(export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [detects_service_name_from_env, deployment_env_from_tenant_id, service_version_from_app,
     detects_service_namespace_from_env, empty_env_var_is_dropped].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(opentelemetry_api),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(detects_service_name_from_env, Config) ->
    os:putenv("OTEL_SERVICE_NAME", "my-test-service"),
    Config;
init_per_testcase(deployment_env_from_tenant_id, Config) ->
    os:putenv("TENANT_ID", "warehouse-prod"),
    Config;
init_per_testcase(detects_service_namespace_from_env, Config) ->
    os:putenv("OTEL_SERVICE_NAMESPACE", "platform"),
    Config;
init_per_testcase(empty_env_var_is_dropped, Config) ->
    os:putenv("OTEL_SERVICE_NAME", ""),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(detects_service_name_from_env, _Config) ->
    os:unsetenv("OTEL_SERVICE_NAME"),
    ok;
end_per_testcase(deployment_env_from_tenant_id, _Config) ->
    os:unsetenv("TENANT_ID"),
    ok;
end_per_testcase(detects_service_namespace_from_env, _Config) ->
    os:unsetenv("OTEL_SERVICE_NAMESPACE"),
    ok;
end_per_testcase(empty_env_var_is_dropped, _Config) ->
    os:unsetenv("OTEL_SERVICE_NAME"),
    ok;
end_per_testcase(_, _Config) ->
    ok.

%% @doc When OTEL_SERVICE_NAME is set, service.name is present with the correct value.
detects_service_name_from_env(_Config) ->
    Resource = service_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assert(maps:is_key('service.name', AttrMap)),
    ?assertEqual(<<"my-test-service">>, maps:get('service.name', AttrMap)).

%% @doc When TENANT_ID is set, deployment.environment is present with the correct value.
deployment_env_from_tenant_id(_Config) ->
    Resource = service_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    ?assert(maps:is_key('deployment.environment', AttrMap)),
    ?assertEqual(<<"warehouse-prod">>, maps:get('deployment.environment', AttrMap)).

%% @doc service.version is populated from the running application's vsn key when available.
%% If not running inside an app (standalone), the key is simply absent (no crash).
service_version_from_app(_Config) ->
    Resource = service_detector:detect(),
    AttrMap = otel_attributes:map(otel_resource:attributes(Resource)),
    %% service.version may or may not be present depending on whether we are
    %% inside a started application — just ensure no crash and the map is valid.
    ?assert(is_map(AttrMap)),
    case maps:find('service.version', AttrMap) of
        {ok, Vsn} ->
            ?assert(is_binary(Vsn));
        error ->
            ok
    end.

%% @doc When OTEL_SERVICE_NAMESPACE is set, service.namespace is present with the correct value.
detects_service_namespace_from_env(_Config) ->
    Map = otel_attributes:map(otel_resource:attributes(service_detector:detect())),
    <<"platform">> = maps:get('service.namespace', Map),
    ok.

%% @doc When OTEL_SERVICE_NAME is set to an empty string, service.name is not emitted.
empty_env_var_is_dropped(_Config) ->
    Map = otel_attributes:map(otel_resource:attributes(service_detector:detect())),
    false = maps:is_key('service.name', Map),
    ok.
