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
%% @doc Convenience facade: merge all BEAM-aware detectors into one Resource.
%%
%% Calls {@link beam_runtime_detector}, {@link host_detector}, and
%% {@link service_detector} in order, merging the results into a single
%% {@link otel_resource:t()}. In case of key conflicts, earlier detectors
%% take precedence (beam_runtime > host > service).
%% @end
%%%------------------------------------------------------------------------
-module(opentelemetry_resource_detector_erlang).

-behaviour(otel_resource_detector).

-export([detect/0, get_resource/1]).

%% @doc Convenience entry-point — same result as {@link get_resource/1},
%% returned directly without going through the SDK behaviour interface.
-spec detect() -> otel_resource:t().
detect() ->
    R1 = beam_runtime_detector:detect(),
    R2 = host_detector:detect(),
    R3 = service_detector:detect(),
    otel_resource:merge(otel_resource:merge(R1, R2), R3).

%% @doc {@link otel_resource_detector} behaviour callback. The SDK's
%% `resource_detectors' sys.config entry calls this with a per-detector
%% config term (we ignore it — all our detectors are config-less and
%% read from the environment / BEAM at detect time).
-spec get_resource(term()) -> otel_resource:t().
get_resource(_Config) ->
    detect().
