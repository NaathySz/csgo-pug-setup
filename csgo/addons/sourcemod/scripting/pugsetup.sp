#define PLUGIN_VERSION  "0.5.0"
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <adminmenu>



/***********************
 *                     *
 *   Global variables  *
 *                     *
 ***********************/

/** ConVar handles **/
new Handle:g_hCvarVersion = INVALID_HANDLE;
new Handle:g_hAutoLO3 = INVALID_HANDLE;
new Handle:g_hLivePlayers = INVALID_HANDLE;
new Handle:g_hWarmupCfg = INVALID_HANDLE;
new Handle:g_hLiveCfg = INVALID_HANDLE;
new Handle:g_hAutorecord = INVALID_HANDLE;

/** Setup info **/
new g_Leader = -1;
new bool:g_Setup = false;
new bool:g_mapSet = false;
new bool:g_Recording = true;
new TeamType:g_TeamType;
new MapType:g_MapType;

/** Permissions for the chat commands **/
enum Permissions {
    Permission_All,
    Permission_Captains,
    Permission_Leader
}

/** Different ways teams can be selected **/
enum TeamType {
    TeamType_Manual,
    TeamType_Random,
    TeamType_Captains
};

/** Different ways the map can be selected **/
enum MapType {
    MapType_Current,
    MapType_Vote
};

/** Map-voting variables **/
#define MAP_NAME_LENGTH 256
new Handle:g_MapNames = INVALID_HANDLE;
new Handle:g_MapVotes = INVALID_HANDLE;
new g_VotesCasted = 0;

/** Data about team selections **/
new g_capt1 = -1;
new g_capt2 = -1;
new g_Teams[MAXPLAYERS+1];
new bool:g_Ready[MAXPLAYERS+1];
new bool:g_MatchLive = false;

#include "pugsetup/liveon3.sp"
#include "pugsetup/setupmenus.sp"
#include "pugsetup/playermenus.sp"



/***********************
 *                     *
 * Sourcemod overrides *
 *                     *
 ***********************/

public Plugin:myinfo = {
    name = "CS:GO PugSetup",
    author = "splewis",
    description = "Tools for setting up pugs/10mans",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-pug-setup"
};

public OnPluginStart() {
    LoadTranslations("common.phrases");

    /** ConVars **/
    g_hWarmupCfg = CreateConVar("sm_pugsetup_warmup_cfg", "sourcemod/pugsetup/warmup.cfg", "Config file to run before/after games");
    g_hLiveCfg = CreateConVar("sm_pugsetup_live_cfg", "sourcemod/pugsetup/standard.cfg", "Config file to run when a game goes live");
    g_hAutoLO3 = CreateConVar("sm_pugsetup_autolo3", "1", "If the game starts immediately after teams are picked");
    g_hLivePlayers = CreateConVar("sm_pugsetup_numplayers", "10", "Minimum Number of players needed to go live");
    g_hAutorecord = CreateConVar("sm_pugsetup_autorecord", "1", "Should the plugin attempt to record a gotv demo each game");
    g_hCvarVersion = CreateConVar("sm_pugsetup_version", PLUGIN_VERSION, "Current pugsetup version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    SetConVarString(g_hCvarVersion, PLUGIN_VERSION);

    /** Create and exec plugin's configuration file **/
    AutoExecConfig(true, "pugsetup", "sourcemod/pugsetup");

    /** Commands **/
    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say2");
    AddCommandListener(Command_Say, "say_team");

    RegConsoleCmd("sm_ready", Command_Ready, "Marks the client as ready");
    RegConsoleCmd("sm_unready", Command_Unready, "Marks the client as not ready");

    RegAdminCmd("sm_setup", Command_Setup, ADMFLAG_CHANGEMAP, "Starts 10man setup (!ready, !capt commands become avaliable)");
    RegAdminCmd("sm_start", Command_Start, ADMFLAG_CHANGEMAP, "Starts the game if auto-lo3 is disabled");
    RegAdminCmd("sm_rand", Command_Rand, ADMFLAG_CHANGEMAP, "Sets random captains");
    RegAdminCmd("sm_capt1", Command_Capt1, ADMFLAG_CHANGEMAP, "Sets captain 1 (picks first, T)");
    RegAdminCmd("sm_capt2", Command_Capt2, ADMFLAG_CHANGEMAP, "Sets captain 2 (picks second, CT)");
    RegAdminCmd("sm_pause", Command_Pause, ADMFLAG_GENERIC, "Pauses the game");
    RegAdminCmd("sm_unpause", Command_Unpause, ADMFLAG_GENERIC, "Unpauses the game");
    RegAdminCmd("sm_endgame", Command_EndGame, ADMFLAG_CHANGEMAP, "Pre-emptively ends the match");
    RegAdminCmd("sm_leader", Command_Leader, ADMFLAG_CHANGEMAP, "Sets the pug leader");

    /** Event hooks **/
    HookEvent("cs_win_panel_match", Event_MatchOver);
}


public OnClientConnected(client) {
    g_Teams[client] = CS_TEAM_SPECTATOR;
    g_Ready[client] = false;
}

public OnClientDisconnect(client) {
    g_Teams[client] = CS_TEAM_SPECTATOR;
    g_Ready[client] = false;
}

public OnMapStart() {
    g_capt1 = -1;
    g_capt2 = -1;
    g_Recording = false;

    for (new i = 1; i <= MaxClients; i++) {
        g_Ready[i] = false;
        g_Teams[i] = -1;
    }

    if (g_mapSet) {
        ExecCfg(g_hWarmupCfg);
        g_Setup = true;
        CreateTimer(1.0, Timer_CheckReady, _, TIMER_REPEAT);
    }
}

public OnMapEnd() {
}

public Action:Timer_CheckReady(Handle:timer) {
    if (!g_Setup || g_MatchLive)
        return Plugin_Stop;

    new rdy = 0;
    new count = 0;
    for (new i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsClientInGame(i) && !IsFakeClient(i)) {
            count++;
            if (g_Ready[i]) {
                CS_SetClientClanTag(i, "[Ready]");
                rdy++;
            } else {
                CS_SetClientClanTag(i, "[Not ready]");
            }
        }
    }

    if (rdy == count && rdy >= GetConVarInt(g_hLivePlayers)) {
        if (g_mapSet) {
            if (g_TeamType == TeamType_Captains) {
                if (IsValidClient(g_capt1) && IsValidClient(g_capt2) && g_capt1 != g_capt2) {
                    CreateTimer(1.0, StartPicking);
                    return Plugin_Stop;
                } else {
                    decl String:cap1[60];
                    decl String:cap2[60];
                    if (IsValidClient(g_capt1) && !IsFakeClient(g_capt1) && IsClientInGame(g_capt1))
                        Format(cap1, sizeof(cap1), "%N", g_capt1);
                    else
                        Format(cap1, sizeof(cap1), "not selected");

                    if (IsValidClient(g_capt2) && !IsFakeClient(g_capt2) && IsClientInGame(g_capt2))
                        Format(cap2, sizeof(cap2), "%N", g_capt2);
                    else
                        Format(cap2, sizeof(cap2), "not selected");

                    PrintHintTextToAll("Captain 1: %s\nCaptain 2: %s",cap1, cap2);

                }
            } else {
                if (GetConVarInt(g_hAutoLO3) != 0) {
                    Command_Start(0, 0);
                } else {
                    PrintToChatAll("Everybody is ready! Waiting for \x04%N \x01to type .start", GetLeader());
                    PrintToChat(GetLeader(), "Everybody is ready! Use \x04.start \x01to begin the match.");
                }
                return Plugin_Stop;
            }

        } else {
            if (g_MapType == MapType_Vote)
                PrintToChatAll(" \x01\x0B\x04The map vote will begin in a few seconds!");
            CreateTimer(2.0, MapSetup);
            return Plugin_Stop;
        }

    } else {
        PrintHintTextToAll("%i out of %i players are ready\nType .ready to ready up", rdy, count);
    }

    return Plugin_Continue;
}



/***********************
 *                     *
 *     Commands        *
 *                     *
 ***********************/

public Action:Command_Setup(client, args) {
    if (g_Setup) {
        PrintSetupInfo(client);
        return Plugin_Handled;
    }

    g_capt1 = -1;
    g_capt2 = -1;
    g_Setup = true;
    g_Leader = GetSteamAccountID(client);
    for (new i = 1; i <= MaxClients; i++)
        g_Ready[i] = false;

    SetupMenu(client);
    return Plugin_Handled;
}

public Action:Command_Rand(client, args) {
    if (!g_Setup || g_MatchLive)
        return Plugin_Handled;

    SetRandomCaptains();
    return Plugin_Handled;
}


public Action:Command_Capt1(client, args) {
    if (!g_Setup || g_MatchLive || g_TeamType != TeamType_Captains || !g_mapSet)
        return Plugin_Handled;

    new String:arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    new target = FindTarget(client, arg1);
    if (target == -1)
        return Plugin_Handled;

    if (target == g_capt2) {
        PrintToChat(client, "%N is already captain 1!", target);
        return Plugin_Handled;
    }

    SetCapt1(target);
    return Plugin_Handled;
}

public Action:Command_Capt2(client, args) {
    if (!g_Setup || g_MatchLive || g_TeamType != TeamType_Captains || !g_mapSet)
        return Plugin_Handled;

    new String:arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    new target = FindTarget(client, arg1);
    if (target == -1)
        return Plugin_Handled;

    if (target == g_capt1) {
        PrintToChat(client, "%N is already captain 2!", target);
        return Plugin_Handled;
    }

    SetCapt2(target);
    return Plugin_Handled;
}

public Action:Command_Start(client, args) {
    if (!g_Setup || g_MatchLive)
        return;

    if (GetConVarInt(g_hAutorecord) != 0) {
        // get the time
        new timeStamp = GetTime();
        decl String:formattedTime[128];
        FormatTime(formattedTime, sizeof(formattedTime), "%Y_%b_%d_%H:%M", timeStamp);

        // get the map
        decl String:mapName[128];
        GetCurrentMap(mapName, sizeof(mapName));

        decl String:demoName[256];
        Format(demoName, sizeof(demoName), "pug_%s_%s", mapName, formattedTime);
        ServerCommand("tv_record %s", demoName);
        g_Recording = true;
    }


    ExecCfg(g_hLiveCfg);
    g_MatchLive = true;
    if (g_TeamType == TeamType_Random) {
        PrintToChatAll("*** \x04Scrambling the teams \x01***");
        ServerCommand("mp_scrambleteams");
    }

    for (new i = 0; i < 5; i++)
        PrintToChatAll("*** The match will begin shortly - live on 3! ***");
    CreateTimer(7.0, BeginLO3);
}

// ChatAlias(String:chatAlias, commandfunction, Permissions:permissions)
#define ChatAlias(%1,%2,%3) \
if (StrEqual(text[0], %1)) { \
    if (HasPermissions(client, %3)) { \
        %2 (client, 0); \
    } else { \
        PrintToChat(client, "You don't have the permissons to do that."); \
    } \
}

public Action:Command_Say(client, const String:command[], argc) {
    decl String:text[192];
    if (GetCmdArgString(text, sizeof(text)) < 1) {
        return Plugin_Continue;
    }

    StripQuotes(text);

    ChatAlias(".setup", Command_Setup, Permission_All)
    ChatAlias(".start", Command_Start, Permission_Leader)
    ChatAlias(".endgame", Command_EndGame, Permission_Leader)
    ChatAlias(".rand", Command_Rand, Permission_Leader)
    ChatAlias(".gaben", Command_Ready, Permission_All)
    ChatAlias(".ready", Command_Ready, Permission_All)
    ChatAlias(".unready", Command_Unready, Permission_All)
    ChatAlias(".pause", Command_Pause, Permission_Captains)
    ChatAlias(".unpause", Command_Unpause, Permission_Captains)

    // there is no sm_help command since we don't want override the built-in sm_help command
    if (StrEqual(text[0], ".help")) {
        PrintToChat(client, " \x04Useful commands:");
        PrintToChat(client, "   \x06.setup \x01begins the setup phase");
        PrintToChat(client, "   \x06.start \x01starts the match if needed");
        PrintToChat(client, "   \x06.endgame \x01ends the match");
        PrintToChat(client, "   \x06.rand \x01selects random captains");
        PrintToChat(client, "   \x06.ready/.unready \x01mark you as ready");
        PrintToChat(client, "   \x06.pause/.unpause \x01pause the match");
    }

    // continue normally
    return Plugin_Continue;
}

public bool:HasPermissions(client, Permissions:p) {
    new bool:isLeader = GetLeader() == client;
    new bool:isCapt = isLeader || client == g_capt1 || client == g_capt2;

    if (p == Permission_Leader)
        return isLeader;
    else if (p == Permission_Captains)
        return isCapt;
    else if (p == Permission_All)
        return true;
    else
        LogError("Unknown permission: %d", p);

    return false;

}

public Action:Command_EndGame(client, args) {
    if (!g_Setup) {
        PrintToChat(client, "The match has not begun yet!");
    } else {
        new Handle:menu = CreateMenu(MatchEndHandler);
        SetMenuTitle(menu, "Are you sure you want to end the match?");
        SetMenuExitButton(menu, true);
        AddMenuItem(menu, "continue", "No, continue the match");
        AddMenuItem(menu, "end", "Yes, end the match");
        DisplayMenu(menu, client, 20);
    }
    return Plugin_Handled;
}

public MatchEndHandler(Handle:menu, MenuAction:action, param1, param2) {
    if (action == MenuAction_Select) {
        new client = param1;
        decl String:choice[16];
        GetMenuItem(menu, param2, choice, sizeof(choice));
        if (StrEqual(choice, "end")) {
            PrintToChatAll("The match was force-ended by \x04%N", client);
            EndMatch();
        }
    } else if (action == MenuAction_End) {
        CloseHandle(menu);
    }
}

public Action:Command_Pause(client, args) {
    if (!g_Setup || !g_MatchLive)
        return Plugin_Handled;

    if (IsValidClient(client)) {
        ServerCommand("mp_pause_match");
        PrintToChatAll(" \x01\x0B\x04%N \x01has called for a pause", client);
    }
    return Plugin_Handled;
}

public Action:Command_Unpause(client, args) {
    if (!g_Setup || !g_MatchLive)
        return Plugin_Handled;

    if (IsValidClient(client)) {
        ServerCommand("mp_unpause_match");
        PrintToChatAll(" \x01\x0B\x04%N \x01has unpaused", client);
    }
    return Plugin_Handled;
}

public Action:Command_Ready(client, args) {
    if (!g_Setup || g_MatchLive)
        return Plugin_Handled;

    g_Ready[client] = true;
    CS_SetClientClanTag(client, "[Ready]");
    return Plugin_Handled;
}

public Action:Command_Unready(client, args) {
    if (!g_Setup || g_MatchLive)
        return Plugin_Handled;

    g_Ready[client] = false;
    CS_SetClientClanTag(client, "[Not ready]");
    return Plugin_Handled;
}

public Action:Command_Leader(client, args) {
    if (!g_Setup)
        return Plugin_Handled;

    new String:arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    new target = FindTarget(client, arg1);
    if (target == -1)
        return Plugin_Handled;

    PrintToChatAll("The new leader is \x04%N", target);
    g_Leader = GetSteamAccountID(target);
    return Plugin_Handled;
}


/***********************
 *                     *
 *       Events        *
 *                     *
 ***********************/

public Action:Event_MatchOver(Handle:event, const String:name[], bool:dontBroadcast) {
    EndMatch();
    return Plugin_Handled;
}



/***********************
 *                     *
 *    Pugsetup logic   *
 *                     *
 ***********************/

public PrintSetupInfo(client) {
        PrintToChat(client, "The game has been setup by \x04%N.", GetLeader());

        decl String:buffer[32];
        GetTeamString(buffer, sizeof(buffer), g_TeamType);
        PrintToChat(client, "   Team setup choice: \x03%s", buffer);

        GetMapString(buffer, sizeof(buffer), g_MapType);
        PrintToChat(client, "   Map setup choice: \x03%s", buffer);
}

public SetCapt1(client) {
    if (IsValidClient(client)) {
        g_capt1 = client;
        PrintToChatAll("Captain 1 will be \x06%N", g_capt1);
    }
}

public SetCapt2(client) {
    if (IsValidClient(client)) {
        g_capt2 = client;
        PrintToChatAll("Captain 2 will be \x07%N", g_capt2);
    }
}

public SetRandomCaptains() {
    new c1 = -1;
    new c2 = -1;

    c1 = RandomPlayer();
    while (!IsValidClient(c2) || c1 == c2) {
        if (GetRealClientCount() < 2)
            break;

        c2 = RandomPlayer();
    }

    SetCapt1(c1);
    SetCapt2(c2);
}

public EndMatch() {
    if (g_Recording) {
        CreateTimer(3.0, StopDemoMsg);
        CreateTimer(4.0, StopDemo);
    }

    ServerCommand("mp_unpause_match");
    if (g_MatchLive)
        ExecCfg(g_hWarmupCfg);

    g_Leader = -1;
    g_capt1 = -1;
    g_capt2 = -1;
    g_Setup = false;
    g_MatchLive = false;
}

public Action:MapSetup(Handle:timer) {
    if (g_MapType == MapType_Vote) {
        CreateMapVote();
    }
    return Plugin_Handled;
}

public Action:StartPicking(Handle:timer) {
    ServerCommand("mp_pause_match");
    ServerCommand("mp_restartgame 1");

    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            g_Teams[i] = CS_TEAM_SPECTATOR;
            SwitchPlayerTeam(i, CS_TEAM_SPECTATOR);
            CS_SetClientClanTag(i, "");
        }
    }

    // temporary teams
    SwitchPlayerTeam(g_capt2, CS_TEAM_CT);
    SwitchPlayerTeam(g_capt1, CS_TEAM_T);
    InitialChoiceMenu(g_capt2);
    return Plugin_Handled;
}

public Action:FinishPicking(Handle:timer) {
    for (new i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            g_Ready[i] = false;
            SwitchPlayerTeam(i, g_Teams[i]);
        }
    }

    ServerCommand("mp_unpause_match");
    if (GetConVarInt(g_hAutoLO3) != 0) {
        Command_Start(0, 0);
    }
    return Plugin_Handled;
}

public Action:StopDemoMsg(Handle:timer) {
    PrintToChatAll("*** Stopping the demo ***");
    return Plugin_Handled;
}

public Action:StopDemo(Handle:timer) {
    ServerCommand("tv_stoprecord");
    g_Recording = false;
    return Plugin_Handled;
}



/***********************
 *                     *
 *  Generic Functions  *
 *                     *
 ***********************/

/**
 * Returns if a client is valid.
 */
public bool:IsValidClient(client) {
    if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
        return true;
    return false;
}

/**
 * Returns the number of clients that are actual players in the game.
 */
public GetRealClientCount() {
    new clients = 0;
    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            clients++;
        }
    }
    return clients;
}

/**
 * Returns a random player client on the server.
 */
public RandomPlayer() {
    new client = -1;
    while (!IsValidClient(client) || IsFakeClient(client)) {
        if (GetRealClientCount() < 1)
            return -1;

        client = GetRandomInt(1, MaxClients);
    }
    return client;
}

/**
 * Switches and respawns a player onto a new team.
 */
public SwitchPlayerTeam(client, team) {
    if (team > CS_TEAM_SPECTATOR) {
        CS_SwitchTeam(client, team);
        CS_UpdateClientModel(client);
        CS_RespawnPlayer(client);
    } else {
        ChangeClientTeam(client, team);
    }
}

/**
 * Returns the client whose steam account id matches the parameter, or -1 if none are found.
 */
public GetLeader() {
    new leaderID = g_Leader;
    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && !IsFakeClient(i) && GetSteamAccountID(i) == leaderID)
            return i;
    }

    new r = RandomPlayer();
    g_Leader = GetSteamAccountID(r);
    return r;
}

/**
 * Executes a config file named by a con var.
 */
public ExecCfg(Handle:ConVarName) {
    new String:cfg[256];
    GetConVarString(ConVarName, cfg, sizeof(cfg));
    ServerCommand("exec %s", cfg);
}

/**
 * Adds an integer to a menu as a string choice.
 */
public AddMenuInt(Handle:menu, any:value, String:display[]) {
    decl String:buffer[8];
    IntToString(value, buffer, sizeof(buffer));
    AddMenuItem(menu, buffer, display);
}

/**
 * Gets an integer to a menu from a string choice.
 */
public GetMenuInt(Handle:menu, any:param2) {
    decl String:choice[8];
    GetMenuItem(menu, param2, choice, sizeof(choice));
    return StringToInt(choice);
}