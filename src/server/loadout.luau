--!strict
-- Spawn loadout (PRODUCT layer, NOT engine): players spawn holding the
-- rocket launcher with 10 rockets — playtests found it's the gun the
-- game is fun with, and ad arrivals shouldn't have to learn pickup
-- routes before touching it. Gated by the spawn_rl attribute on
-- QuakeAssets (absent = ON, the mildmode convention; the `original`
-- modifier and presets whose mods run their own loadouts set false)
-- AND by deathmatch rules, so campaign/coop stay authentic. Attribute
-- is live-flippable: it gates each grant, applying from the next spawn.
--
-- Grants ride the health RISING edge (<=0 to >0) each heartbeat: that
-- is PutClientInServer's signature for first spawn AND every respawn,
-- and it fires AFTER QC reset the inventory (granting any earlier gets
-- wiped by that reset). The boot-side grant ORs the RL bit into .items,
-- tops rockets up to 10, and queues impulse 7 so QC's W_ChangeWeapon
-- does the switch bookkeeping (weaponmodel/currentammo) itself on the
-- next PlayerPreThink.
--
-- REMOVAL: delete this file and the marked "spawn loadout" blocks in
-- init.server.luau / qwserver.luau, and drop spawn_rl from
-- modepresets.KEYS + the `original` modifier.

export type SlotRead = {
	health: number,
}
export type Adapter = {
	maxclients: number,
	readSlot: (slot: number) -> SlotRead?, -- nil for inactive/spectator slots
	-- pokes the live edict: RL item bit, rockets top-up, impulse 7
	grant: (slot: number) -> (),
}

return function(assets: Instance)
	-- per-slot last observed health; nil = slot was inactive (slot reuse
	-- by the next player starts from the inactive state, so their first
	-- spawn reads as a rising edge too)
	local lastHealth: { [number]: number? } = {}

	local api = {}

	-- boot calls every server heartbeat
	function api.step(a: Adapter)
		local enabled = assets:GetAttribute("spawn_rl") ~= false
			and (tonumber(assets:GetAttribute("deathmatch")) or 0) ~= 0
		for slot = 1, a.maxclients do
			local read = a.readSlot(slot)
			if not read then
				lastHealth[slot] = nil
				continue
			end
			local last = lastHealth[slot]
			lastHealth[slot] = read.health
			if enabled and read.health > 0 and (last == nil or last <= 0) then
				a.grant(slot)
			end
		end
	end

	return api
end
