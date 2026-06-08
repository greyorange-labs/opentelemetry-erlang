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
%% @doc Resource detector for host.* and os.* attributes.
%% @end
%%%------------------------------------------------------------------------
-module(host_detector).

-export([detect/0, host_id_fallback/1]).

%% @doc Detects host and OS resource attributes.
%%
%% Returns a resource containing:
%% <ul>
%%   <li>`host.name' — resolved hostname</li>
%%   <li>`host.arch' — system architecture string</li>
%%   <li>`host.id' — machine-id from /etc/machine-id, or MD5 hash of hostname</li>
%%   <li>`os.type' — `<<"linux">>', `<<"darwin">>', or `<<"windows">>'</li>
%%   <li>`os.description' — full ERTS system_version string</li>
%% </ul>
-spec detect() -> otel_resource:t().
detect() ->
    HostName = host_name(),
    HostArch = iolist_to_binary(erlang:system_info(system_architecture)),
    OsType = os_type_atom_to_binary(element(1, os:type())),
    HostId = host_id(HostName),
    OsDesc = iolist_to_binary(string:trim(erlang:system_info(system_version), trailing, "\n")),
    Attrs = [
        {<<"host.name">>, HostName},
        {<<"host.arch">>, HostArch},
        {<<"host.id">>, HostId},
        {<<"os.type">>, OsType},
        {<<"os.description">>, OsDesc}
    ],
    otel_resource:create(Attrs).

%%

host_name() ->
    {ok, Name} = inet:gethostname(),
    list_to_binary(Name).

os_type_atom_to_binary(unix) ->
    case os:type() of
        {unix, darwin} -> <<"darwin">>;
        _              -> <<"linux">>
    end;
os_type_atom_to_binary(win32) -> <<"windows">>.

host_id(HostName) ->
    case file:read_file("/etc/machine-id") of
        {ok, MachineId} ->
            iolist_to_binary(string:trim(MachineId, trailing, "\n"));
        _ ->
            host_id_fallback(HostName)
    end.

%% @doc Computes a host ID by MD5-hashing the hostname.
%% Used as a fallback when /etc/machine-id is not available.
-spec host_id_fallback(binary()) -> binary().
host_id_fallback(HostName) ->
    <<Hash:128>> = crypto:hash(md5, HostName),
    list_to_binary(integer_to_list(Hash, 16)).
