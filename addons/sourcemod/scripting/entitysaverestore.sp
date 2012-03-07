
// enforce semicolons after each code statement
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <playerhooks>
#include <smlib>
#include <config>

#define PLUGIN_VERSION "2.0a"



/*****************************************************************


		P L U G I N   I N F O


*****************************************************************/

public Plugin:myinfo = {
	name = "Entity Save & Restore",
	author = "Berni",
	description = "Entity Save & Restore",
	version = PLUGIN_VERSION,
	url = "http://www.mannisfunhouse.eu"
}



/*****************************************************************


		G L O B A L   V A R S


*****************************************************************/

// ConVar Handles

// Misc
new String:configPath[PLATFORM_MAX_PATH] = "\0";
new Handle:config					= INVALID_HANDLE;

new Handle:saveClassnames			= INVALID_HANDLE;
new Handle:ignoreEntityModels		= INVALID_HANDLE;

new Handle:entityQueue				= INVALID_HANDLE;
new Handle:entityQueue_isMapEntity	= INVALID_HANDLE;

new Handle:spawn_entity				= INVALID_HANDLE;
new Handle:spawn_isMapEntity		= INVALID_HANDLE;
new Handle:spawn_spawnOrigin		= INVALID_HANDLE;

//new bool:isLateLoad					= false;
//new bool:isFirstOnMapStart			= true;
new bool:newEntitiesinQueue			= false;
new countSaveEntities				= 0;
new bool:counting					= false;
new bool:isMapLoaded				= false;
new bool:createNewSaveState			= false;
//new bool:restoreSaveEntities		= false;
new bool:restoreEntities			= false;

// SQL
new Handle:hDatabase				= INVALID_HANDLE;
new serial							= -1;
new lastSaveStateId					= -1;
new currentSaveStateId				= -1;
new isSystemReady					= false;
new Handle:sql_queue				= INVALID_HANDLE;



/*****************************************************************


		F O R W A R D   P U B L I C S


*****************************************************************/

public OnPluginStart() {
	
	RegAdminCmd("sm_savestate",		Command_SaveState,		ADMFLAG_ROOT);
	RegAdminCmd("sm_restorestate",	Command_RestoreState,	ADMFLAG_ROOT);
	
	BuildPath(Path_SM, configPath, sizeof(configPath), "configs/entitysaverestore.cfg");
	
	saveClassnames			= CreateArray(32);
	ignoreEntityModels		= CreateArray(PLATFORM_MAX_PATH);
	// Entity creation frame delay
	entityQueue				= CreateArray();
	entityQueue_isMapEntity	= CreateArray();
	
	spawn_entity			= CreateArray();
	spawn_isMapEntity		= CreateArray();
	spawn_spawnOrigin		= CreateArray(3);
	
	sql_queue 				= CreateArray(4096);
	
	config = ConfigCreate();
	
	StartSQL("entitysaverestore");
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max) {
	
	//isLateLoad = late;
	
	return APLRes_Success;
}

public OnConfigsExecuted() {
	
	ReadSettings();
}

public OnMapStart() {
	
	isMapLoaded = true;

	/*if (isLateLoad && isFirstOnMapStart) {
		isFirstOnMapStart = false;
		return;
	}*/
	
	if (isSystemReady && restoreEntities) {
		createNewSaveState = true;
		if (lastSaveStateId != -1) {
			RestoreEntities(lastSaveStateId);
		}
	}
}

public OnMapEnd() {
	
	isMapLoaded = false;
	lastSaveStateId = currentSaveStateId;
	currentSaveStateId = -1;
	restoreEntities = true;
}

public OnEntityCreated(entity, const String:className[]) {
	
	PushArrayCell(entityQueue, entity);
	PushArrayCell(entityQueue_isMapEntity, (isMapLoaded==false));
	newEntitiesinQueue = true;
	
}

public OnEntityDestroyed(entity) {
	
	decl String:className[64];
	decl String:m_ModelName[PLATFORM_MAX_PATH];

	GetEdictClassname(entity, className, sizeof(className));
	Entity_GetModel(entity, m_ModelName, sizeof(m_ModelName));
	
	if (!IsSaveAbleEntity(className, m_ModelName)) {
		return;
	}

	DeleteEntity(entity);
}

public OnGameFrame() {
	
	if (!newEntitiesinQueue) {
		return;
	}
	
	new size = GetArraySize(entityQueue);
	for (new i=0; i<size; i++) {
		OnEntityCreated_Delayed(GetArrayCell(entityQueue, i), GetArrayCell(entityQueue_isMapEntity, i));
	}
	
	ClearArray(entityQueue);
	ClearArray(entityQueue_isMapEntity);
	
	newEntitiesinQueue = false;
}



/****************************************************************


		C A L L B A C K   F U N C T I O N S


****************************************************************/

public Action:Command_SaveState(client, args) {
	
	if (args == 0) {
		ReplyToCommand(client, "Please specify a name for the savestate");
		return Plugin_Handled;
	}
	
	decl String:name[64];
	GetCmdArg(1, name, sizeof(name));
	
	if (!isSystemReady) {
		ReplyToCommand(client, "Can't save state, database not ready yet");
		return Plugin_Handled;
	}
	
	ReplyToCommand(client, "Saving entities to database...");
	SaveEntities(false);
	
	return Plugin_Handled;
}

public Action:Command_RestoreState(client, args) {
	
	if (!isSystemReady) {
		ReplyToCommand(client, "Can't restore state, database not ready yet");
		return Plugin_Handled;
	}
	
	if (args == 0) {
		ReplyToCommand(client, "Please specify a name for the savestate");
		return Plugin_Handled;
	}
	
	decl String:name[64];
	GetCmdArg(1, name, sizeof(name));
	
	ReplyToCommand(client, "Restoring entities from database...");
	RestoreEntities(currentSaveStateId);
	
	return Plugin_Handled;
}

public Action:Timer_SaveEntityProperties(Handle:timer) {
	
	SaveEntities();
}



/*****************************************************************


		P L U G I N   F U N C T I O N S


*****************************************************************/

OnEntityCreated_Delayed(entity, bool:isMapEntity) {
	
	if (!IsValidEdict(entity)) {
		return;
	}

	decl String:className[64];
	decl String:m_ModelName[PLATFORM_MAX_PATH];

	GetEdictClassname(entity, className, sizeof(className));
	Entity_GetModel(entity, m_ModelName, sizeof(m_ModelName));
	
	if (StrContains(className, "prop_", false) != 0) {
		return;
	}
	
	if (!IsSaveAbleEntity(className, m_ModelName)) {
		return;
	}
	
	decl Float:origin[3];
	Entity_GetAbsOrigin(entity, origin);
	
	if (!isSystemReady) {
		PushArrayCell(spawn_entity, entity);
		PushArrayCell(spawn_entity, isMapEntity);
		PushArrayArray(spawn_spawnOrigin, origin);
		return;
	}
	
	SaveEntity(entity, className, m_ModelName, true, isMapEntity);
}

SaveEntities(bool:initialize=false) {
	
	PrintToServer("Debug: SaveEntities()");
	
	decl String:className[64];
	decl String:m_ModelName[PLATFORM_MAX_PATH];
	
	counting = true;
	new maxEntities = GetMaxEntities();
	for (new entity=MaxClients+1; entity<=maxEntities; entity++) {
		
		if (!IsValidEdict(entity)) {
			continue;
		}
		
		GetEdictClassname(entity, className, sizeof(className));
		Entity_GetModel(entity, m_ModelName, sizeof(m_ModelName));

		if (!IsSaveAbleEntity(className, m_ModelName)) {
			continue;
		}
		
		if (StrEqual(m_ModelName, "") || m_ModelName[0] == '*') {
			continue;
		}
		
		SaveEntity(entity, className, m_ModelName, initialize);
		countSaveEntities++;
		
		/*if (countSaveEntities == 2) {
			break;
		}*/
	}
	
	PrintToServer("Debug: Saving %d entities...", countSaveEntities);
}

SaveEntity(entity, const String:className[], const String:model[], bool:create=true, bool:isMapEntity=false, Float:spawnOrigin[3]=NULL_VECTOR) {
	
	if (!IsValidEdict(entity)) {
		return;
	}
	
	new String:query_values[4096] = "\0";
	
	
	decl String:targetname[64];
	decl String:globalname[64];
	decl Float:origin[3];
	decl Float:angles[3];
	decl Float:velocity[3];
	new String:m_vehicleScript[64] = "\0";

	GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
	GetEntPropString(entity, Prop_Data, "m_iGlobalname", globalname, sizeof(globalname));
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
	GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", angles);
	GetEntPropVector(entity, Prop_Data, "m_vecVelocity", velocity);
	
	new m_nRenderFX		= GetEntProp(entity, Prop_Data, "m_nRenderFX", 1);
	new m_nRenderMode	= GetEntProp(entity, Prop_Data, "m_nRenderMode", 1);
	new m_clrRender		= GetEntProp(entity, Prop_Data, "m_clrRender");
	new m_lifeState		= GetEntProp(entity, Prop_Data, "m_lifeState", 1);
	new m_iMaxHealth	= GetEntProp(entity, Prop_Data, "m_iMaxHealth");
	new m_iHealth		= GetEntProp(entity, Prop_Data, "m_iHealth");
	new m_nSolidType	= GetEntProp(entity, Prop_Send, "m_nSolidType", 1);
	new m_usSolidFlags	= GetEntProp(entity, Prop_Data, "m_usSolidFlags", 2);
	new m_MoveType		= GetEntProp(entity, Prop_Data, "m_MoveType", 1);
	new m_MoveCollide	= GetEntProp(entity, Prop_Data, "m_MoveCollide", 1);
	new m_spawnflags	= GetEntProp(entity, Prop_Data, "m_spawnflags");
	new m_takedamage	= GetEntProp(entity, Prop_Data, "m_takedamage", 1);

	new bool:isMotionDisabled = !IsMoveableEntity(entity);

	if (StrContains(className, "prop_vehicle_") == 0) {
		GetEntPropString(entity, Prop_Data, "m_vehicleScript", m_vehicleScript, sizeof(m_vehicleScript));
	}

	new m_bLocked = -1;
	new offset_m_bLocked = FindDataMapOffs(entity, "m_bLocked");
	if (offset_m_bLocked > 0) {
		m_bLocked = GetEntData(entity, offset_m_bLocked, 1);
	}
	
	SQL_EscapeString(hDatabase, targetname, targetname, sizeof(targetname));
	SQL_EscapeString(hDatabase, globalname, globalname, sizeof(globalname));

	Format(
		query_values,
		sizeof(query_values),
		"classname='%s', targetname='%s', globalname='%s', model='%s', origin_0='%f', origin_1='%f', origin_2='%f', angles_0='%f', angles_1='%f', angles_2='%f', velocity_0='%f', velocity_1='%f', velocity_2='%f', m_nRenderFX='%d', m_nRenderMode='%d', m_clrRender='%d', m_lifeState='%d', m_iMaxHealth='%d', m_iHealth='%d', m_nSolidType='%d',m_usSolidFlags ='%d', m_MoveType='%d', m_MoveCollide='%d', m_spawnflags='%d', m_takedamage='%d', isMotionDisabled='%d', m_vehicleScript='%s', m_bLocked='%d'",

		className,
		targetname,
		globalname,
		model,
		origin[0],
		origin[1],
		origin[2],
		angles[0],
		angles[1],
		angles[2],
		velocity[0],
		velocity[1],
		velocity[2],
		m_nRenderFX,
		m_nRenderMode,
		m_clrRender,
		m_lifeState,
		m_iMaxHealth,
		m_iHealth,
		m_nSolidType,
		m_usSolidFlags,
		m_MoveType,
		m_MoveCollide,
		m_spawnflags,
		m_takedamage,
		isMotionDisabled,
		m_vehicleScript,
		m_bLocked
	);
	
	if (create) {
		_SQL_TQueryF(hDatabase, T_SaveEntity, 0, "INSERT INTO entities SET savestate_id='%d', entityindex='%d', spawnorigin_0='%f', spawnorigin_1='%f', spawnorigin_2='%f', ismapentity='%d', %s ON DUPLICATE KEY UPDATE %s", currentSaveStateId, entity, spawnOrigin[0], spawnOrigin[1], spawnOrigin[2],isMapEntity, query_values, query_values);
	}
	else {
		_SQL_TQueryF(hDatabase, T_SaveEntity, 0, "UPDATE entities SET %s WHERE entityindex='%d' && savestate_id='%d'", query_values, entity, currentSaveStateId);
	}
}

DeleteEntity(entity) {
	
	// Whatever matches
	_SQL_TQueryF(hDatabase, T_QueryFinished, 0, "DELETE FROM entities WHERE savestate_id='%d' && entityindex='%d' && ismapentity != '1'", currentSaveStateId, entity);
	_SQL_TQueryF(hDatabase, T_QueryFinished, 0, "UPDATE entities SET `delete`=1 WHERE savestate_id='%d' && entityindex='%d' && ismapentity='1'", currentSaveStateId, entity);
}

ReadSettings() {

	ClearArray(saveClassnames);
	ClearArray(ignoreEntityModels);
	
	decl String:errorMsg[256];
	new line;

	if (!ConfigReadFile(config, configPath, errorMsg, sizeof(errorMsg), line)) {
		SetFailState("Can't read config file %s: %s @ line %d", configPath, errorMsg, line);
	}

	new Handle:save_entities = ConfigLookup(config, "save_entities");
	new Handle:classnames = ConfigSettingGetMember(save_entities, "classnames");

	ConfigArrayToStringAdt(classnames, saveClassnames);
	
	new Handle:ignore_entity_models = ConfigLookup(config, "ignore_entity_models");
	ConfigArrayToStringAdt(ignore_entity_models, ignoreEntityModels);
	
	new Handle:server_serial = ConfigLookup(config, "server_serial");
	serial = ConfigSettingGetInt(server_serial);
}

bool:IsSaveAbleEntity(const String:class[], const String:model[]) {
	
	new size;
	decl String:buffer[PLATFORM_MAX_PATH];
	
	size = GetArraySize(ignoreEntityModels);
	for (new i=0; i<size; i++) {
		GetArrayString(ignoreEntityModels, i, buffer, sizeof(buffer));

		if (StrContains(buffer, model, false) == 0) {
			return false;
		}
	}
	
	size = GetArraySize(saveClassnames);
	for (new i=0; i<size; i++) {
		GetArrayString(saveClassnames, i, buffer, sizeof(buffer));

		if (StrContains(class, buffer, false) == 0) {
			return true;
		}
	}
	
	return false;
}

ConfigArrayToStringAdt(Handle:Setting, Handle:adtArray) {
	
	decl String:buffer[PLATFORM_MAX_PATH];
	new length = ConfigSettingLength(Setting);

	for (new i=0; i<length; i++) {
		ConfigSettingGetStringElement(Setting, i, buffer, sizeof(buffer));
		PushArrayString(adtArray, buffer);
		PrintToServer("Debug: %s", buffer);
	}
}

GenerateNewSerial() {
	SQL_TQueryF(hDatabase, T_GenerateNewSerial, 0, "SELECT MAX(serial)+1 as nextserial FROM savestates", serial);
}

GetLastSaveState() {
	PrintToServer("Debug: GetLastSaveState()");
	SQL_TQueryF(hDatabase, T_GetLastSaveState, 0, "SELECT * FROM savestates WHERE serial='%d' && name='' && useable=1 ORDER BY time DESC LIMIT 1", serial);
}

CreateNewSaveState() {
	
	PrintToServer("Debug: CreateNewSaveState()");

	decl String:mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));

	_SQL_TQueryF(hDatabase, T_CreateNewSaveState, 0, "INSERT INTO savestates (serial, map, time) VALUES ('%d', '%s', '%d')", serial, mapName, GetTime());
}

RestoreEntities(saveStateId) {
	PrintToServer("Debug: RestoreEntities()");
	_SQL_TQueryF(hDatabase, T_RestoreEntities, 0, "SELECT * FROM entities WHERE savestate_id='%d'", saveStateId);
}

bool:RestoreEntity(Handle:hndl) {

	decl Float:spawnOrigin[3];
	spawnOrigin[0]			= SQL_FetchFloatByName(hndl, "spawnorigin_0");
	spawnOrigin[1]			= SQL_FetchFloatByName(hndl, "spawnorigin_1");
	spawnOrigin[2]			= SQL_FetchFloatByName(hndl, "spawnorigin_2");
	new saveStateId			= SQL_FetchIntByName(hndl, "savestate_id");
	new entity				= SQL_FetchIntByName(hndl, "entityindex");
	new ismapentity			= SQL_FetchIntByName(hndl, "ismapentity");
	new delete				= SQL_FetchIntByName(hndl, "delete");
	
	if (IsValidEdict(entity)) {
		if (saveStateId == currentSaveStateId) {
			return false;
		}
	}
	else {
		entity = -1;
	}

	if (ismapentity) {
		
		entity = Entity_GetFromPosition(spawnOrigin);
		
		if (entity != -1 && delete) {
			RemoveEdict(entity);
			return true;
		}
	}
	
	decl String:className[32];
	decl String:model[256];
	decl String:targetname[64];
	decl String:globalname[64];
	decl String:m_vehicleScript[64];
	decl Float:origin[3];
	decl Float:angles[3];
	decl Float:velocity[3];
	
	SQL_FetchStringByName(hndl, "classname", className, sizeof(className));
	SQL_FetchStringByName(hndl, "model", model, sizeof(model));
	SQL_FetchStringByName(hndl, "targetname", targetname, sizeof(targetname));
	SQL_FetchStringByName(hndl, "globalname", globalname, sizeof(globalname));
	SQL_FetchStringByName(hndl, "m_vehicleScript", m_vehicleScript, sizeof(m_vehicleScript));
	origin[0]				= SQL_FetchFloatByName(hndl, "origin_0");
	origin[1]				= SQL_FetchFloatByName(hndl, "origin_1");
	origin[2]				= SQL_FetchFloatByName(hndl, "origin_2");
	angles[0]				= SQL_FetchFloatByName(hndl, "angles_0");
	angles[1]				= SQL_FetchFloatByName(hndl, "angles_1");
	angles[2]				= SQL_FetchFloatByName(hndl, "angles_2");
	velocity[0]				= SQL_FetchFloatByName(hndl, "velocity_0");
	velocity[1]				= SQL_FetchFloatByName(hndl, "velocity_1");
	velocity[2]				= SQL_FetchFloatByName(hndl, "velocity_2");
	new m_nRenderFX			= SQL_FetchIntByName(hndl, "m_nRenderFX");
	new m_nRenderMode		= SQL_FetchIntByName(hndl, "m_nRenderMode");
	new m_clrRender			= SQL_FetchIntByName(hndl, "m_clrRender");
	new m_lifeState			= SQL_FetchIntByName(hndl, "m_lifeState");
	new m_iMaxHealth		= SQL_FetchIntByName(hndl, "m_iMaxHealth");
	new m_iHealth			= SQL_FetchIntByName(hndl, "m_iHealth");
	new m_nSolidType		= SQL_FetchIntByName(hndl, "m_nSolidType");
	new m_usSolidFlags		= SQL_FetchIntByName(hndl, "m_usSolidFlags");
	new m_MoveType			= SQL_FetchIntByName(hndl, "m_MoveType");
	new m_MoveCollide		= SQL_FetchIntByName(hndl, "m_MoveCollide");
	new m_spawnflags		= SQL_FetchIntByName(hndl, "m_spawnflags");
	new m_takedamage		= SQL_FetchIntByName(hndl, "m_takedamage");
	new m_bLocked			= SQL_FetchIntByName(hndl, "m_bLocked");
	new isMotionDisabled	= SQL_FetchIntByName(hndl, "isMotionDisabled");
	
	PrintToServer("Restoring entity: class: %s model: %s...", className, model);

	if (entity == -1) {
		entity = CreateEntityByName(className);

		if (entity == -1) {
			PrintToServer("Failed to create object %d (%s)", entity, className);
			return false;
		}
	}
	
	PrecacheModel(model, true);
	DispatchKeyValue(entity,		"model",			model);
	DispatchKeyValue(entity,		"targetname",		targetname);
	DispatchKeyValue(entity,		"globalname",		globalname);
	DispatchKeyValueVector(entity,	"origin",			origin);
	DispatchKeyValueVector(entity,	"angles",			angles);
	DispatchKeyValueVector(entity,	"velocity",			velocity);
	SetEntProp(entity, Prop_Data,	"m_nRenderFX",		m_nRenderFX,	1);
	SetEntProp(entity, Prop_Data,	"m_nRenderMode",	m_nRenderMode,	1);
	SetEntProp(entity, Prop_Data,	"m_clrRender",		m_clrRender);
	SetEntProp(entity, Prop_Data,	"m_lifeState",	 	m_lifeState,	1);
	SetEntProp(entity, Prop_Data,	"m_iMaxHealth",		m_iMaxHealth);
	SetEntProp(entity, Prop_Data,	"m_iHealth",		m_iHealth,		1);
	SetEntProp(entity, Prop_Data,	"m_nSolidType",		m_nSolidType,	1);
	SetEntProp(entity, Prop_Data,	"m_usSolidFlags", 	m_usSolidFlags,	2);
	SetEntProp(entity, Prop_Data,	"m_MoveType",		m_MoveType,		1);
	SetEntProp(entity, Prop_Data,	"m_MoveCollide",	m_MoveCollide,	1);
	SetEntProp(entity, Prop_Data,	"m_takedamage",		m_takedamage,	1);

	if (m_bLocked != -1) {
		SetEntProp(entity, Prop_Data, "m_bLocked", m_bLocked, 1);
	}

	if (isMotionDisabled) {
		m_spawnflags |= SF_PHYSPROP_MOTIONDISABLED;
		Entity_SetSpawnFlags(entity, m_spawnflags);
	}
	
	if (!StrEqual(m_vehicleScript, "")) {
		DispatchKeyValue(entity, "vehiclescript", m_vehicleScript);
	}
	
	DispatchSpawn(entity);
	ActivateEntity(entity);
	
	return true;
}

CheckSerial() {
	
	if (serial == -1) {
		GenerateNewSerial();
		return;
	}

	GetLastSaveState();
}

SystemReady() {
	
	PrintToServer("Debug: SystemReady()");
	
	ProccessSQLQueue();
	
	isSystemReady = true;
	
	PrintToServer("Debug: isMapLoaded == %d", isMapLoaded);
	if (isMapLoaded) {
		ProccessSpawnQueue();

		if (currentSaveStateId == -1) {
			CreateNewSaveState();
		}
		else {
			SaveEntities(true);
		}
	}
}

ProccessSQLQueue() {
	
	PrintToServer("Debug: ProccessSQLQueue()");
	
	decl String:query[4096];
	
	new size = GetArraySize(sql_queue);
	for (new i=0; i<size; i++) {
		
		SQL_TQueryF(hDatabase, T_QueryFinished, 0, query);
	}
	
	ClearArray(sql_queue);
}

ProccessSpawnQueue() {
	
	PrintToServer("Debug: ProccessSpawnQueue()");
	
	decl String:className[64];
	decl String:m_ModelName[PLATFORM_MAX_PATH];
	decl Float:spawnOrigin[3];
	
	new size=GetArraySize(spawn_entity);
	for (new i=0; i<size; i++) {
		
		new entity = GetArrayCell(spawn_entity, i);
		
		if (!IsValidEdict(entity)) {
			continue;
		}
		
		GetArrayArray(spawn_spawnOrigin, i, spawnOrigin);

		GetEdictClassname(entity, className, sizeof(className));
		Entity_GetModel(entity, m_ModelName, sizeof(m_ModelName));
		
		SaveEntity(entity, className, m_ModelName, true, GetArrayCell(spawn_isMapEntity, i), spawnOrigin);
	}
	
	ClearArray(spawn_entity);
	ClearArray(spawn_isMapEntity);
	ClearArray(spawn_spawnOrigin);
}



/*****************************************************************


		S Q L   F U N C T I O N S


*****************************************************************/

StartSQL(const String:database[]) {
	SQL_TConnect(GotDatabase, database);
}

public GotDatabase(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {
		SetFailState("Database failure: %s", error);
	}

	hDatabase = hndl;
	
	CheckSerial();
}

stock _SQL_TQueryF(Handle:database, SQLTCallback:callback, any:data, const String:format[], any:...) {

	decl String:query[4096];
	VFormat(query, sizeof(query), format, 5);
	
	if (!isSystemReady) {
		PushArrayString(sql_queue, query);
		return;
	}
	
	if (database == INVALID_HANDLE) {
		ThrowError("Database Handle %d is invalid", database);
		return;
	}
	
	//PrintToServer("Query: %s", query);
	
	SQL_TQuery(database, callback, query, data, DBPrio_Normal);
}

public T_QueryFinished(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		LogError("SQL-Query failed. %s", error);
		PrintToServer("SQL-Query failed: %s", error);
		
		return;
	}
}

public T_GetLastSaveState(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		LogError("SQL-Query failed. %s", error);
		PrintToServer("SQL-Query failed: %s", error);
		
		return;
	}
	
	if (SQL_FetchRow(hndl)) {

		new saveStateId = SQL_FetchIntByName(hndl, "id");
		new time = SQL_FetchIntByName(hndl, "time");
		
		if (time >= (GetTime() - GetGameTime())) {
			currentSaveStateId = saveStateId;
		}
		else {
			restoreEntities = true;
		}
	}
	
	SystemReady();
}

public T_GenerateNewSerial(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		SetFailState("Database failure: %s", error);
	}
	
	if (SQL_FetchRow(hndl)) {
		serial = SQL_FetchIntByName(hndl, "nextserial");
	}
	else {
		serial = 1;
	}
	
	new Handle:server_serial = ConfigLookup(config, "server_serial");
	serial = ConfigSettingSetInt(server_serial, serial);
	ConfigWriteFile(config, configPath);
	
	SystemReady();
}

public T_RestoreEntities(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		LogError("SQL-Query failed. %s", error);
		PrintToServer("SQL-Query failed: %s", error);
		
		return;
	}
	
	while (SQL_FetchRow(hndl)) {
		
		RestoreEntity(Handle:hndl);
	}
	
	if (createNewSaveState) {
		createNewSaveState = false;
		CreateNewSaveState();
	}
}

public T_CreateNewSaveState(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		LogError("SQL-Query failed. %s", error);
		PrintToServer("SQL-Query failed: %s", error);
		
		return;
	}

	currentSaveStateId = SQL_GetInsertId(owner);
	
	if (isMapLoaded) {
		SaveEntities(true);
	}
}

public T_SaveEntity(Handle:owner, Handle:hndl, const String:error[], any:data) {
	
	if (hndl == INVALID_HANDLE) {

		LogError("SQL-Query failed. %s", error);
		PrintToServer("SQL-Query failed: %s", error);
	}

	if (countSaveEntities > 0) {
		countSaveEntities--;
	}
	
	if (counting && countSaveEntities == 1) {
		CreateTimer(60.0, Timer_SaveEntityProperties, 0, TIMER_FLAG_NO_MAPCHANGE);
		SQL_TQueryF(hDatabase, T_QueryFinished, 0, "UPDATE savestates SET useable=1 WHERE id='%d'", currentSaveStateId);
		PrintToServer("Done saving entities :)");
		counting = false;
	}
}
