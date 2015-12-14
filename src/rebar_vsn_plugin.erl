%%% -*- mode: Erlang; fill-column: 80; comment-column: 75; -*-
%%% Copyright 2012 Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%---------------------------------------------------------------------------
%%% @author Eric Merrit <ericbmerritt@gmail.com>
%%% @copyright (C) 2012, Eric Merrit
%%% @doc
%%% This module provides a reasonable way to get decent semver compatible vsn
%%% from the system. This uses the rebar post_compile hook to rewrite the app
%%% file metadata with the correct version.
-module(rebar_vsn_plugin).

-export([post_compile/2]).

%% to integrate with another rebar plugins (like the ChicagoBoss' one)
-export([make_vsn/0]).

%%============================================================================
%% API
%%============================================================================
post_compile(_, undefined) -> ok;  % Avoid apps with no AppFile
post_compile(Config, AppFile) ->
  case rebar_app_utils:is_app_dir() of
      {true, AppFile} ->
          process_app_vsn(Config, AppFile);
      _ ->
          ok
  end.

%% Public function to build up a default VSN from wherever needed
make_vsn() ->
    {Vsn, RawRef, RawCount} = collect_default_refcount(),
    build_vsn_string(Vsn, RawRef, RawCount).

%%============================================================================
%% Internal Functions
%%============================================================================
process_app_vsn(Config, AppFile) ->
    case get_app_meta(Config, AppFile) of
        {ok, {AppName, SrcDetail}} ->
            VsnOpts = rebar_config:get(Config, vsn_opts, []),

            IsOverrided =
                case proplists:get_value(override_vsn_for_apps, VsnOpts, false) of
                    false -> false;
                    {incl, Pattern} -> check_if_app_overrided(AppName, Pattern);
                    {excl, Pattern} -> not(check_if_app_overrided(AppName, Pattern))
                end,

            Version =
                if
                    IsOverrided -> proplists:get_value(override_vsn, VsnOpts);
                    true        -> proplists:get_value(vsn, SrcDetail)
                end,

            FinaleVersion =
                case Version of
                    {custom, CustomVersion} ->
                        process_custom_version(CustomVersion);
                    Semver when Semver =:= "semver" orelse
                                Semver =:= semver ->
                        {TagVsn, RawRef, RawCount} = collect_default_refcount(),
                        build_vsn_string(TagVsn, RawRef, RawCount);
                    Vsn when erlang:is_list(Vsn);
                             erlang:is_binary(Vsn) ->
                        check_smart_replacement(AppName, Config, AppFile, Vsn);
                    _ ->
                        false
                end,
            rebar_log:log(warn, "VERSION: ~p~n", [FinaleVersion]),
            case FinaleVersion of
                false -> ok;
                _     -> rewrite_vsn(Config, AppName, AppFile, FinaleVersion)
            end;
        {error, _} ->
            ok
    end.

process_custom_version(CustomVersion) ->
    binary_to_list(iolist_to_binary(lists:map(fun do_process_custom_version/1, CustomVersion))).

do_process_custom_version({env_var, VariableName}) ->
    case os:getenv(VariableName) of
        false -> "";
        Value -> Value
    end;
do_process_custom_version(epoch) ->
    {MegaSecs, Secs, _MicroSecs} = erlang:now(),
    integer_to_list((MegaSecs * 1000000) + Secs);
do_process_custom_version(git_ref) ->
    {_TagVsn, RawRef, _RawCount} = collect_default_refcount(),
    RawRef;
do_process_custom_version(git_tag) ->
    {TagVsn, _RawRef, _RawCount} = collect_default_refcount(),
    TagVsn;
do_process_custom_version(commits_number) ->
    {_TagVsn, _RawRef, RawCount} = collect_default_refcount(),
    RawCount;
do_process_custom_version(ConstString) ->
    ConstString.

check_if_app_overrided(AppName, [H | _] = AppsList) when is_atom(H) ->
    lists:member(AppName, AppsList);
check_if_app_overrided(AppName, Regexp) ->
    case re:run(atom_to_list(AppName), Regexp) of
        {match, _} -> true;
        nomatch    -> false
    end.

check_smart_replacement(AppName, Config, AppFile, Vsn) ->
    case rebar_config:get_local(Config, plugins, []) of
        [] ->
            false;
        PluginList ->
            case lists:member(?MODULE, PluginList) of
                true ->
                    do_smart_replacement(AppName, Config, AppFile, Vsn);
                false ->
                    false
            end
    end.

do_smart_replacement(AppName, Config, AppFile, Vsn) ->
    GitTopLevel = get_git_root(),
    LocalAppFile = string:sub_string(AppFile, erlang:length(GitTopLevel) + 1),
    {Ref, _} = case get_revision_list(AppFile) of
                 [] ->
                       {workspace, "0.0.0"};
                 Revisions ->
                     find_change_ref(Revisions, LocalAppFile, workspace, Vsn)
               end,
    figure_out_patch_version(Config, AppName, LocalAppFile, Ref, Vsn).

figure_out_patch_version(_Config, _AppName, _AppFile, workspace, Vsn) ->
    build_vsn_string(Vsn, undefined, <<"0">>);
figure_out_patch_version(_Config, _AppName, _AppFile, Ref, Vsn) ->
    RawCount = get_patch_count(Ref),
    build_vsn_string(Vsn, Ref, RawCount).

find_change_ref([], _LocalAppFile, _LastRevision, _Vsn) ->
    {no_ref, "0.0.0"};
find_change_ref([FileRevision], _LocalAppFile, _LastRevision, Vsn) ->
    {FileRevision, Vsn};
find_change_ref([FileRevision | Rest], LocalAppFile, LastRevision, Vsn) ->
    case get_version(FileRevision, LocalAppFile) of
        Vsn ->
            %% No change here
            find_change_ref(Rest, LocalAppFile, FileRevision, Vsn);
        DifferentVsn ->
            {LastRevision, DifferentVsn}
    end.

get_version(NewestReversion, AppFile) ->
    Contents = os:cmd(io_lib:format("git show ~s:~s~n", [NewestReversion, AppFile])),
    {ok, Scanned, _} = erl_scan:string(Contents),
    {ok, {application, _, AppMeta}} = erl_parse:parse_term(Scanned),
    proplists:get_value(vsn, AppMeta).

get_revision_list(AppFile) ->
   string:tokens(os:cmd(io_lib:format("git log --format=%h -- ~s~n", [AppFile])),
                 "\n\r").

get_ref() ->
    re:replace(os:cmd("git log -n 1 --pretty=format:'%h\n' "),  "\\s", "", [global]).
get_ref_count() ->
    re:replace(os:cmd("git rev-list HEAD | wc -l"), "\\s", "", [global]).

collect_default_refcount() ->
    %% Get the tag timestamp and minimal ref from the system. The
    %% timestamp is really important from an ordering perspective.
    RawRef = get_ref(),

    {Tag, TagVsn} = parse_tags(),
    RawCount =
        case Tag of
            undefined -> get_ref_count();
            _ -> get_patch_count(RawRef)
        end,
    {TagVsn, RawRef, RawCount}.

rewrite_vsn(Config, AppName, AppFile, Vsn) ->
    EbinAppFile= filename:join("ebin", erlang:atom_to_list(AppName) ++ ".app"),
    case get_app_meta(Config, EbinAppFile) of
        {ok, {AppName, Details0}} ->
            %% Replace the old version with the new one
            Details1 = lists:keyreplace(vsn, 1, Details0, {vsn, Vsn}),
            write_app_file(EbinAppFile, {application, AppName, Details1}),
            update_config(Config, AppName, AppFile, Details1);
        {error, _} ->
            ok
    end.

build_vsn_string(Vsn, RawRef, RawCount) ->
    %% Cleanup the tag and the Ref information. Basically leading 'v's and
    %% whitespace needs to go away.
    RefTag = case RawRef of
                 undefined ->
                     "";
                 RawRef ->
                     [".ref", RawRef]
             end,
    Count = erlang:iolist_to_binary(RawCount),

    %% Create the valid [semver](http://semver.org) version from the tag
    case Count of
        <<"0">> ->
            erlang:binary_to_list(erlang:iolist_to_binary(Vsn));
        _ ->
            erlang:binary_to_list(erlang:iolist_to_binary([Vsn, "+build.",
                                                           Count, RefTag]))
    end.

get_patch_count(RawRef) ->
    Ref = re:replace(RawRef, "\\s", "", [global]),
    Cmd = io_lib:format("git rev-list ~s..HEAD | wc -l",
                         [Ref]),
    os:cmd(Cmd).

write_app_file(AppFile, AppTerms) ->
    AppHeader = "%% VSN was autogenerated by rebar_vsn_plugin\n\n",
    file:write_file(AppFile, [AppHeader, io_lib:fwrite("~p. ", [AppTerms])]).

parse_tags() ->
    first_valid_tag(os:cmd("git log --oneline --decorate  | fgrep \"tag: \" -1000")).

first_valid_tag(Line) ->
    case re:run(Line, "(\\(|\\s)tag:\\s(v?([^,\\)]+))", [{capture, [2, 3], list}]) of
        {match,[Tag, Vsn]} ->
            {Tag, Vsn};
        nomatch ->
            {undefined, "0.0.0"}
    end.

update_config(Config, AppName, AppFile, Details) ->
    case lists:member({set_xconf, 3}, rebar_config:module_info(exports)) of
        true ->
            {ok, rebar_config:set_xconf(Config, {appfile, {app_file, AppFile}},
                                        {AppName, Details})};
        false ->
            ok
    end.

get_app_meta(Config, EbinAppFile) ->
    case lists:member({get_xconf, 2}, rebar_config:module_info(exports)) of
        true ->
            {ok, rebar_config:get_xconf(Config, {appfile, {app_file, EbinAppFile}}, [])};
        false ->
            case file:consult(EbinAppFile) of
                {ok, [{application, AppName, Details}]} ->
                    {ok, {AppName, Details}};
                {ok, _} ->
                    rebar_log:log(warn, "Skipping non-app file: ~s~n", [EbinAppFile]),
                    {error, non_app};
                _ ->
                    rebar_log:log(warn, "Unable to read app file: ~s~n", [EbinAppFile]),
                    %% does our inability to read the .app file imply
                    %% it is not an application at all?
                    {error, non_app}
            end
    end.

get_git_root() ->
    os:cmd("git rev-parse --show-toplevel").
