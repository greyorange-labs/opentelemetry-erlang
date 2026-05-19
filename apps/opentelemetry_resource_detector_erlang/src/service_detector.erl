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
%%
%% @doc Resource detector for service.* and deployment.environment.
%%
%% Reads from the following environment variables:
%% <ul>
%%   <li>`OTEL_SERVICE_NAME' → `service.name'</li>
%%   <li>`OTEL_SERVICE_NAMESPACE' → `service.namespace'</li>
%%   <li>`TENANT_ID' → `deployment.environment'</li>
%% </ul>
%% `service.version' is read from the running application's `vsn' key when available.
%% @end
%%%------------------------------------------------------------------------
-module(service_detector).

-export([detect/0]).

%% @doc Detects service resource attributes.
%%
%% Attributes are only included when the corresponding source is non-empty.
-spec detect() -> otel_resource:t().
detect() ->
    Attrs = lists:filter(
        fun({_K, V}) -> V =/= undefined end,
        [
            {<<"service.name">>, from_env("OTEL_SERVICE_NAME")},
            {<<"service.namespace">>, from_env("OTEL_SERVICE_NAMESPACE")},
            {<<"service.version">>, current_app_version()},
            {<<"deployment.environment">>, from_env("TENANT_ID")}
        ]),
    otel_resource:create(Attrs).

%%

current_app_version() ->
    case application:get_application() of
        {ok, App} ->
            case application:get_key(App, vsn) of
                {ok, Vsn} -> list_to_binary(Vsn);
                _ -> undefined
            end;
        _ ->
            undefined
    end.

from_env(Var) ->
    case os:getenv(Var) of
        false -> undefined;
        "" -> undefined;
        V -> list_to_binary(V)
    end.
