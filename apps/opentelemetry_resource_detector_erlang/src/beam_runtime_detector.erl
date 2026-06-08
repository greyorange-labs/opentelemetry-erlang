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
%% @doc Resource detector for process.* and process.runtime.* attributes.
%% Java OTel agent equivalent populates the same attributes at JVM init.
%% @end
%%%------------------------------------------------------------------------
-module(beam_runtime_detector).

-export([detect/0]).

%% @doc Detects BEAM runtime resource attributes.
%%
%% Returns a resource containing:
%% <ul>
%%   <li>`process.pid' — OS PID of the current BEAM node</li>
%%   <li>`process.runtime.name' — always `<<"BEAM">>'</li>
%%   <li>`process.runtime.version' — OTP release / ERTS version</li>
%%   <li>`process.runtime.description' — full system_version string</li>
%% </ul>
-spec detect() -> otel_resource:t().
detect() ->
    OsPid = list_to_integer(os:getpid()),
    OtpRelease = erlang:system_info(otp_release),
    Version = lists:flatten(io_lib:format("~s/~s", [OtpRelease, erlang:system_info(version)])),
    Description = erlang:system_info(system_version),
    Attrs = [
        {<<"process.pid">>, OsPid},
        {<<"process.runtime.name">>, <<"BEAM">>},
        {<<"process.runtime.version">>, iolist_to_binary(Version)},
        {<<"process.runtime.description">>, iolist_to_binary(string:trim(Description, trailing, "\n"))}
    ],
    otel_resource:create(Attrs).
