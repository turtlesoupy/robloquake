--!strict
--!optimize 2
-- BSP29 brush model loading — port of the BRUSHMODEL LOADING section of
-- WinQuake model.c (Mod_LoadBrushModel and friends) plus Mod_PointInLeaf,
-- Mod_DecompressVis and Mod_LeafPVS.
--
-- Representation conventions (used engine-wide):
--   * Luau arrays are 1-based, but every stored cross-reference index keeps
--     the original C 0-based value; lookup sites add 1. Fields named *num or
--     first* hold C indices.
--   * Sign conventions from the C structs are preserved verbatim: node
--     children < 0 mean -(leafnum+1), clipnode children < 0 are CONTENTS_*.
--   * vec3_t becomes the Luau `vector` type (f32 components, same storage
--     precision as the C engine).

local bufio = require("../common/bufio")

local bsp = {}

bsp.BSPVERSION = 29

-- lump directory indices (LUMP_* in bspfile.h); 0-based into the header
local LUMP_ENTITIES = 0
local LUMP_PLANES = 1
local LUMP_TEXTURES = 2
local LUMP_VERTEXES = 3
local LUMP_VISIBILITY = 4
local LUMP_NODES = 5
local LUMP_TEXINFO = 6
local LUMP_FACES = 7
local LUMP_LIGHTING = 8
local LUMP_CLIPNODES = 9
local LUMP_LEAFS = 10
local LUMP_MARKSURFACES = 11
local LUMP_EDGES = 12
local LUMP_SURFEDGES = 13
local LUMP_MODELS = 14
local HEADER_LUMPS = 15

bsp.CONTENTS_EMPTY = -1
bsp.CONTENTS_SOLID = -2
bsp.CONTENTS_WATER = -3
bsp.CONTENTS_SLIME = -4
bsp.CONTENTS_LAVA = -5
bsp.CONTENTS_SKY = -6

bsp.TEX_SPECIAL = 1

-- msurface_t flags (model.h)
bsp.SURF_PLANEBACK = 2
bsp.SURF_DRAWSKY = 4
bsp.SURF_DRAWSPRITE = 8
bsp.SURF_DRAWTURB = 0x10
bsp.SURF_DRAWTILED = 0x20
bsp.SURF_DRAWBACKGROUND = 0x40

local MAX_MAP_HULLS = 4
local MIPLEVELS = 4
local ANIM_CYCLE = 2

export type Plane = {
	normal: vector,
	dist: number,
	type: number, -- PLANE_X..PLANE_ANYZ
	signbits: number,
}

export type Texture = {
	name: string,
	width: number,
	height: number,
	-- full mip chain, w*h/64*85 bytes; offsets[k] (1-based array of the 4
	-- mip levels) are relative to this buffer's start
	pixels: buffer,
	offsets: { number },
	anim_total: number, -- total tenths in sequence (0 = not animated)
	anim_min: number,
	anim_max: number,
	anim_next: Texture?,
	alternate_anims: Texture?,
}

export type TexInfo = {
	-- [s/t][xyz offset] flattened: s = vecs[1..4], t = vecs[5..8]
	vecs: { number },
	miptex: number, -- C index into textures
	flags: number,
	texture: Texture?,
	mipadjust: number,
}

export type Surface = {
	num: number, -- C surface index
	planenum: number,
	flags: number,
	firstedge: number, -- C index into surfedges
	numedges: number,
	texinfonum: number,
	texturemins: { number }, -- [2]
	extents: { number }, -- [2]
	styles: { number }, -- [4] of lightstyle indices (255 = unused)
	lightofs: number, -- byte offset into lightdata, -1 = none
}

export type Node = {
	planenum: number,
	-- C encoding: >= 0 node index, < 0 is -(leafnum+1)
	children: { number },
	minmaxs: { number }, -- [6]
	firstsurface: number,
	numsurfaces: number,
}

export type Leaf = {
	num: number, -- C leaf index (0 = shared solid leaf)
	contents: number,
	visofs: number, -- byte offset into visdata, -1 = none
	minmaxs: { number }, -- [6]
	firstmarksurface: number, -- C index into marksurfaces
	nummarksurfaces: number,
	ambient: { number }, -- [4] NUM_AMBIENTS sound levels
}

export type ClipNodes = {
	-- parallel arrays indexed by C clipnode index + 1
	planenum: { number },
	child0: { number }, -- C encoding: >= 0 clipnode index, < 0 contents
	child1: { number },
}

export type Hull = {
	clipnodes: ClipNodes,
	planes: { Plane },
	firstclipnode: number,
	lastclipnode: number,
	clip_mins: vector,
	clip_maxs: vector,
}

export type Submodel = {
	mins: vector,
	maxs: vector,
	origin: vector,
	headnode: { number }, -- [MAX_MAP_HULLS], C values
	visleafs: number,
	firstface: number,
	numfaces: number,
}

-- Shared per-BSP-file data (one per .bsp, referenced by every submodel)
export type BspData = {
	vertexes: { vector },
	edges0: { number }, -- edge -> first vertex C index
	edges1: { number }, -- edge -> second vertex C index
	surfedges: { number },
	textures: { Texture? }, -- 1-based; nil where dataofs was -1
	numtextures: number,
	lightdata: buffer?,
	visdata: buffer?,
	entities: string,
	planes: { Plane },
	texinfo: { TexInfo },
	surfaces: { Surface },
	marksurfaces: { number }, -- C surface indices
	leafs: { Leaf },
	nodes: { Node },
	clipnodes: ClipNodes,
	numclipnodes: number,
	hull0: ClipNodes, -- node tree duplicated as clipnodes (Mod_MakeHull0)
	submodels: { Submodel },
}

export type Model = {
	name: string,
	brush: BspData,
	mins: vector,
	maxs: vector,
	radius: number,
	hulls: { Hull }, -- [1..MAX_MAP_HULLS] (hull index h = hulls[h+1])
	firstmodelsurface: number,
	nummodelsurfaces: number,
	numleafs: number, -- visleafs, not counting solid leaf 0
}

type Lump = { fileofs: number, filelen: number }

local function readLumps(buf: buffer): { Lump }
	local r = bufio.reader(buf)
	local version = r:i32()
	if version ~= bsp.BSPVERSION then
		error(`bsp version {version}, should be {bsp.BSPVERSION}`)
	end
	local lumps = table.create(HEADER_LUMPS)
	for _ = 1, HEADER_LUMPS do
		local fileofs = r:i32()
		local filelen = r:i32()
		table.insert(lumps, { fileofs = fileofs, filelen = filelen })
	end
	return lumps
end

local function lumpReader(buf: buffer, lumps: { Lump }, index: number, entsize: number): (bufio.Reader, number)
	local l = lumps[index + 1]
	if l.filelen % entsize ~= 0 then
		error(`funny lump size (lump {index})`)
	end
	return bufio.reader(buf, l.fileofs), l.filelen / entsize
end

local function loadVertexes(buf: buffer, lumps: { Lump }): { vector }
	local r, count = lumpReader(buf, lumps, LUMP_VERTEXES, 12)
	local out = table.create(count)
	for _ = 1, count do
		table.insert(out, r:vec3())
	end
	return out
end

local function loadEdges(buf: buffer, lumps: { Lump }): ({ number }, { number })
	local r, count = lumpReader(buf, lumps, LUMP_EDGES, 4)
	local v0 = table.create(count)
	local v1 = table.create(count)
	for _ = 1, count do
		table.insert(v0, r:u16())
		table.insert(v1, r:u16())
	end
	return v0, v1
end

local function loadSurfedges(buf: buffer, lumps: { Lump }): { number }
	local r, count = lumpReader(buf, lumps, LUMP_SURFEDGES, 4)
	local out = table.create(count)
	for _ = 1, count do
		table.insert(out, r:i32())
	end
	return out
end

-- Mod_LoadTextures including the '+' animation sequencing
local function loadTextures(buf: buffer, lumps: { Lump }): ({ Texture? }, number)
	local l = lumps[LUMP_TEXTURES + 1]
	if l.filelen == 0 then
		return {}, 0
	end
	local base = l.fileofs
	local r = bufio.reader(buf, base)
	local nummiptex = r:i32()
	local dataofs = table.create(nummiptex)
	for _ = 1, nummiptex do
		table.insert(dataofs, r:i32())
	end

	local textures: { Texture? } = table.create(nummiptex)
	for i = 1, nummiptex do
		textures[i] = nil
		if dataofs[i] == -1 then
			continue
		end
		local mt = bufio.reader(buf, base + dataofs[i])
		local name = mt:strz(16)
		local width = mt:u32()
		local height = mt:u32()
		local offsets = table.create(MIPLEVELS)
		for _ = 1, MIPLEVELS do
			table.insert(offsets, mt:u32())
		end
		if width % 16 ~= 0 or height % 16 ~= 0 then
			error(`texture {name} is not 16 aligned`)
		end
		local pixels = width * height / 64 * 85
		local headerSize = 40 -- sizeof(miptex_t); pixel data follows it
		for k = 1, MIPLEVELS do
			offsets[k] -= headerSize
		end
		textures[i] = {
			name = name,
			width = width,
			height = height,
			pixels = bufio.slice(buf, base + dataofs[i] + headerSize, pixels),
			offsets = offsets,
			anim_total = 0,
			anim_min = 0,
			anim_max = 0,
			anim_next = nil,
			alternate_anims = nil,
		}
	end

	-- sequence the animations ('+0name'..'+9name' and '+aname'..'+jname')
	for i = 1, nummiptex do
		local tx = textures[i]
		if not tx or tx.name:sub(1, 1) ~= "+" then
			continue
		end
		if tx.anim_next then
			continue -- already sequenced
		end

		local anims: { Texture? } = {}
		local altanims: { Texture? } = {}
		local max, altmax
		local c = tx.name:byte(2)
		if c >= 97 and c <= 122 then -- 'a'..'z'
			c -= 32
		end
		if c >= 48 and c <= 57 then -- '0'..'9'
			max = c - 48
			altmax = 0
			anims[max] = tx
			max += 1
		elseif c >= 65 and c <= 74 then -- 'A'..'J'
			altmax = c - 65
			max = 0
			altanims[altmax] = tx
			altmax += 1
		else
			error(`bad animating texture {tx.name}`)
		end

		for j = i + 1, nummiptex do
			local tx2 = textures[j]
			if not tx2 or tx2.name:sub(1, 1) ~= "+" then
				continue
			end
			if tx2.name:sub(3) ~= tx.name:sub(3) then
				continue
			end
			local num = tx2.name:byte(2)
			if num >= 97 and num <= 122 then
				num -= 32
			end
			if num >= 48 and num <= 57 then
				num -= 48
				anims[num] = tx2
				if num + 1 > max then
					max = num + 1
				end
			elseif num >= 65 and num <= 74 then
				num -= 65
				altanims[num] = tx2
				if num + 1 > altmax then
					altmax = num + 1
				end
			else
				error(`bad animating texture {tx.name}`)
			end
		end

		-- link them all together (anims/altanims are 0-based sequences)
		for j = 0, max - 1 do
			local tx2 = anims[j]
			if not tx2 then
				error(`missing frame {j} of {tx.name}`)
			end
			tx2.anim_total = max * ANIM_CYCLE
			tx2.anim_min = j * ANIM_CYCLE
			tx2.anim_max = (j + 1) * ANIM_CYCLE
			tx2.anim_next = anims[(j + 1) % max]
			if altmax ~= 0 then
				tx2.alternate_anims = altanims[0]
			end
		end
		for j = 0, altmax - 1 do
			local tx2 = altanims[j]
			if not tx2 then
				error(`missing frame {j} of {tx.name}`)
			end
			tx2.anim_total = altmax * ANIM_CYCLE
			tx2.anim_min = j * ANIM_CYCLE
			tx2.anim_max = (j + 1) * ANIM_CYCLE
			tx2.anim_next = altanims[(j + 1) % altmax]
			if max ~= 0 then
				tx2.alternate_anims = anims[0]
			end
		end
	end

	return textures, nummiptex
end

local function loadBlob(buf: buffer, lumps: { Lump }, index: number): buffer?
	local l = lumps[index + 1]
	if l.filelen == 0 then
		return nil
	end
	return bufio.slice(buf, l.fileofs, l.filelen)
end

local function loadPlanes(buf: buffer, lumps: { Lump }): { Plane }
	local r, count = lumpReader(buf, lumps, LUMP_PLANES, 20)
	local out = table.create(count)
	for _ = 1, count do
		local normal = r:vec3()
		local bits = 0
		if normal.x < 0 then
			bits += 1
		end
		if normal.y < 0 then
			bits += 2
		end
		if normal.z < 0 then
			bits += 4
		end
		table.insert(out, {
			normal = normal,
			dist = r:f32(),
			type = r:i32(),
			signbits = bits,
		})
	end
	return out
end

local function loadTexinfo(buf: buffer, lumps: { Lump }, textures: { Texture? }, numtextures: number): { TexInfo }
	local r, count = lumpReader(buf, lumps, LUMP_TEXINFO, 40)
	local out = table.create(count)
	for _ = 1, count do
		local vecs = table.create(8)
		for _ = 1, 8 do
			table.insert(vecs, r:f32())
		end
		local len1 = math.sqrt(vecs[1] ^ 2 + vecs[2] ^ 2 + vecs[3] ^ 2)
		local len2 = math.sqrt(vecs[5] ^ 2 + vecs[6] ^ 2 + vecs[7] ^ 2)
		local len = (len1 + len2) / 2
		local mipadjust
		if len < 0.32 then
			mipadjust = 4
		elseif len < 0.49 then
			mipadjust = 3
		elseif len < 0.99 then
			mipadjust = 2
		else
			mipadjust = 1
		end
		local miptex = r:i32()
		local flags = r:i32()
		local texture: Texture? = nil
		if numtextures > 0 then
			if miptex >= numtextures then
				error("miptex >= numtextures")
			end
			texture = textures[miptex + 1]
			if not texture then
				flags = 0 -- texture not found: r_notexture_mip, no flags
			end
		else
			flags = 0
		end
		table.insert(out, {
			vecs = vecs,
			miptex = miptex,
			flags = flags,
			texture = texture,
			mipadjust = mipadjust,
		})
	end
	return out
end

-- CalcSurfaceExtents
local function calcSurfaceExtents(data: BspData, s: Surface)
	local mins = { 999999, 999999 }
	local maxs = { -99999, -99999 }
	local tex = data.texinfo[s.texinfonum + 1]
	local vecs = tex.vecs

	for i = 0, s.numedges - 1 do
		local e = data.surfedges[s.firstedge + i + 1]
		local v: vector
		if e >= 0 then
			v = data.vertexes[data.edges0[e + 1] + 1]
		else
			v = data.vertexes[data.edges1[-e + 1] + 1]
		end
		for j = 1, 2 do
			local o = (j - 1) * 4
			local val = v.x * vecs[o + 1] + v.y * vecs[o + 2] + v.z * vecs[o + 3] + vecs[o + 4]
			if val < mins[j] then
				mins[j] = val
			end
			if val > maxs[j] then
				maxs[j] = val
			end
		end
	end

	for i = 1, 2 do
		local bmins = math.floor(mins[i] / 16)
		local bmaxs = math.ceil(maxs[i] / 16)
		s.texturemins[i] = bmins * 16
		s.extents[i] = (bmaxs - bmins) * 16
		if bit32.band(tex.flags, bsp.TEX_SPECIAL) == 0 and s.extents[i] > 256 then
			error("bad surface extents")
		end
	end
end

local function loadFaces(buf: buffer, lumps: { Lump }, data: BspData): { Surface }
	local r, count = lumpReader(buf, lumps, LUMP_FACES, 20)
	local out = table.create(count)
	data.surfaces = out
	for surfnum = 0, count - 1 do
		local planenum = r:i16()
		local side = r:i16()
		local firstedge = r:i32()
		local numedges = r:i16()
		local texinfonum = r:i16()
		local styles = { r:u8(), r:u8(), r:u8(), r:u8() }
		local lightofs = r:i32()

		local s: Surface = {
			num = surfnum,
			planenum = planenum,
			flags = if side ~= 0 then bsp.SURF_PLANEBACK else 0,
			firstedge = firstedge,
			numedges = numedges,
			texinfonum = texinfonum,
			texturemins = { 0, 0 },
			extents = { 0, 0 },
			styles = styles,
			lightofs = lightofs,
		}
		calcSurfaceExtents(data, s)

		-- drawing flags from the texture name
		local tex = data.texinfo[texinfonum + 1].texture
		if tex then
			if tex.name:sub(1, 3) == "sky" then
				s.flags = bit32.bor(s.flags, bsp.SURF_DRAWSKY, bsp.SURF_DRAWTILED)
			elseif tex.name:sub(1, 1) == "*" then
				s.flags = bit32.bor(s.flags, bsp.SURF_DRAWTURB, bsp.SURF_DRAWTILED)
				for i = 1, 2 do
					s.extents[i] = 16384
					s.texturemins[i] = -8192
				end
			end
		end

		table.insert(out, s)
	end
	return out
end

local function loadMarksurfaces(buf: buffer, lumps: { Lump }, numsurfaces: number): { number }
	local r, count = lumpReader(buf, lumps, LUMP_MARKSURFACES, 2)
	local out = table.create(count)
	for _ = 1, count do
		local j = r:i16()
		if j >= numsurfaces then
			error("bad surface number")
		end
		table.insert(out, j)
	end
	return out
end

local function loadLeafs(buf: buffer, lumps: { Lump }): { Leaf }
	local r, count = lumpReader(buf, lumps, LUMP_LEAFS, 28)
	local out = table.create(count)
	for i = 0, count - 1 do
		local contents = r:i32()
		local visofs = r:i32()
		local minmaxs = table.create(6)
		for _ = 1, 6 do
			table.insert(minmaxs, r:i16())
		end
		local firstmarksurface = r:u16()
		local nummarksurfaces = r:u16()
		local ambient = { r:u8(), r:u8(), r:u8(), r:u8() }
		table.insert(out, {
			num = i,
			contents = contents,
			visofs = visofs,
			minmaxs = minmaxs,
			firstmarksurface = firstmarksurface,
			nummarksurfaces = nummarksurfaces,
			ambient = ambient,
		})
	end
	return out
end

local function loadNodes(buf: buffer, lumps: { Lump }): { Node }
	local r, count = lumpReader(buf, lumps, LUMP_NODES, 24)
	local out = table.create(count)
	for _ = 1, count do
		local planenum = r:i32()
		local children = { r:i16(), r:i16() }
		local minmaxs = table.create(6)
		for _ = 1, 6 do
			table.insert(minmaxs, r:i16())
		end
		local firstsurface = r:u16()
		local numsurfaces = r:u16()
		table.insert(out, {
			planenum = planenum,
			children = children,
			minmaxs = minmaxs,
			firstsurface = firstsurface,
			numsurfaces = numsurfaces,
		})
	end
	return out
end

local function loadClipnodes(buf: buffer, lumps: { Lump }): (ClipNodes, number)
	local r, count = lumpReader(buf, lumps, LUMP_CLIPNODES, 8)
	local planenum = table.create(count)
	local child0 = table.create(count)
	local child1 = table.create(count)
	for _ = 1, count do
		table.insert(planenum, r:i32())
		table.insert(child0, r:i16())
		table.insert(child1, r:i16())
	end
	return { planenum = planenum, child0 = child0, child1 = child1 }, count
end

-- Mod_MakeHull0: duplicate the node tree as a clipping hull
local function makeHull0(nodes: { Node }): ClipNodes
	local count = #nodes
	local planenum = table.create(count)
	local child0 = table.create(count)
	local child1 = table.create(count)
	for i = 1, count do
		local n = nodes[i]
		table.insert(planenum, n.planenum)
		-- node children >= 0 stay node indices; leaf children become their
		-- contents value (C walks the pointer; the disk encoding -(leaf+1)
		-- must be decoded through the leaf table built by loadLeafs)
		table.insert(child0, n.children[1])
		table.insert(child1, n.children[2])
	end
	return { planenum = planenum, child0 = child0, child1 = child1 }
end

local function loadSubmodels(buf: buffer, lumps: { Lump }): { Submodel }
	local r, count = lumpReader(buf, lumps, LUMP_MODELS, 64)
	local out = table.create(count)
	for _ = 1, count do
		local mins = r:vec3()
		local maxs = r:vec3()
		local origin = r:vec3()
		local headnode = table.create(MAX_MAP_HULLS)
		for _ = 1, MAX_MAP_HULLS do
			table.insert(headnode, r:i32())
		end
		table.insert(out, {
			-- spread the mins / maxs by a pixel
			mins = mins - vector.one,
			maxs = maxs + vector.one,
			origin = origin,
			headnode = headnode,
			visleafs = r:i32(),
			firstface = r:i32(),
			numfaces = r:i32(),
		})
	end
	return out
end

local function radiusFromBounds(mins: vector, maxs: vector): number
	local corner = vector.max(vector.abs(mins), vector.abs(maxs))
	return vector.magnitude(corner)
end

-- Mod_LoadBrushModel. Returns the list of models: [1] is the world (or the
-- bmodel itself), [2..] are the "*n" submodels sharing the same BspData.
-- Worldspawn "message" field (the level's display name, e.g. what the HUD
-- shows) WITHOUT parsing geometry — reads only the header + entity lump, so
-- it is cheap enough to run over a whole rotation. Returns nil for a bad
-- BSP, a missing lump, or no message key. Worldspawn is always the first
-- entity block, so scanning it alone avoids matching a trigger's message.
function bsp.readTitle(buf: buffer): string?
	local ok, title = pcall(function(): string?
		local lumps = readLumps(buf)
		local entblob = loadBlob(buf, lumps, LUMP_ENTITIES)
		if not entblob then
			return nil
		end
		local ents = bufio.cstring(entblob, 0)
		local worldspawn = ents:match("{(.-)}") -- first block
		if not worldspawn then
			return nil
		end
		return worldspawn:match('"message"%s*"([^"]*)"')
	end)
	return if ok then title else nil
end

function bsp.load(name: string, buf: buffer): { Model }
	local lumps = readLumps(buf)

	local data = {} :: BspData
	data.vertexes = loadVertexes(buf, lumps)
	data.edges0, data.edges1 = loadEdges(buf, lumps)
	data.surfedges = loadSurfedges(buf, lumps)
	data.textures, data.numtextures = loadTextures(buf, lumps)
	data.lightdata = loadBlob(buf, lumps, LUMP_LIGHTING)
	data.planes = loadPlanes(buf, lumps)
	data.texinfo = loadTexinfo(buf, lumps, data.textures, data.numtextures)
	data.surfaces = loadFaces(buf, lumps, data)
	data.marksurfaces = loadMarksurfaces(buf, lumps, #data.surfaces)
	data.visdata = loadBlob(buf, lumps, LUMP_VISIBILITY)
	data.leafs = loadLeafs(buf, lumps)
	data.nodes = loadNodes(buf, lumps)
	data.clipnodes, data.numclipnodes = loadClipnodes(buf, lumps)
	local entblob = loadBlob(buf, lumps, LUMP_ENTITIES)
	data.entities = if entblob then bufio.cstring(entblob, 0) else ""
	data.submodels = loadSubmodels(buf, lumps)
	data.hull0 = makeHull0(data.nodes)

	-- Mod_MakeHull0's tree references leaf *contents* where the node tree
	-- references leaves; decode -(leafnum+1) children into contents now.
	local h0 = data.hull0
	for i = 1, #data.nodes do
		local c = h0.child0[i]
		if c < 0 then
			h0.child0[i] = data.leafs[-c].contents -- -(-1-c) - ... : leafnum = -1-c, +1 for array = -c
		end
		c = h0.child1[i]
		if c < 0 then
			h0.child1[i] = data.leafs[-c].contents
		end
	end

	-- set up the submodels: each gets its own hulls with per-model headnodes
	local models: { Model } = table.create(#data.submodels)
	for i = 1, #data.submodels do
		local bm = data.submodels[i]
		local hulls: { Hull } = table.create(MAX_MAP_HULLS)

		hulls[1] = {
			clipnodes = data.hull0,
			planes = data.planes,
			firstclipnode = bm.headnode[1],
			lastclipnode = #data.nodes - 1,
			clip_mins = vector.zero,
			clip_maxs = vector.zero,
		}
		hulls[2] = {
			clipnodes = data.clipnodes,
			planes = data.planes,
			firstclipnode = bm.headnode[2],
			lastclipnode = data.numclipnodes - 1,
			clip_mins = vector.create(-16, -16, -24),
			clip_maxs = vector.create(16, 16, 32),
		}
		hulls[3] = {
			clipnodes = data.clipnodes,
			planes = data.planes,
			firstclipnode = bm.headnode[3],
			lastclipnode = data.numclipnodes - 1,
			clip_mins = vector.create(-32, -32, -24),
			clip_maxs = vector.create(32, 32, 64),
		}
		hulls[4] = {
			clipnodes = data.clipnodes,
			planes = data.planes,
			firstclipnode = bm.headnode[4],
			lastclipnode = data.numclipnodes - 1,
			clip_mins = vector.zero,
			clip_maxs = vector.zero,
		}

		table.insert(models, {
			name = if i == 1 then name else `*{i - 1}`,
			brush = data,
			mins = bm.mins,
			maxs = bm.maxs,
			radius = radiusFromBounds(bm.mins, bm.maxs),
			hulls = hulls,
			firstmodelsurface = bm.firstface,
			nummodelsurfaces = bm.numfaces,
			numleafs = bm.visleafs,
		})
	end
	return models
end

-- Mod_PointInLeaf: returns the leaf table containing point p.
function bsp.pointInLeaf(p: vector, model: Model): Leaf
	local data = model.brush
	local nodes = data.nodes
	local planes = data.planes
	local num = 0 -- world node 0 (WinQuake always starts at model->nodes)
	while true do
		local node = nodes[num + 1]
		local plane = planes[node.planenum + 1]
		local d = vector.dot(p, plane.normal) - plane.dist
		local child = if d > 0 then node.children[1] else node.children[2]
		if child < 0 then
			return data.leafs[-child] -- leafnum = -1-child; array index leafnum+1 = -child
		end
		num = child
	end
end

-- Mod_DecompressVis / Mod_LeafPVS. Returns a bit buffer of
-- (model.numleafs+7)/8 bytes; bit (leafnum-1) set = leaf visible.
function bsp.leafPVS(leaf: Leaf, model: Model): buffer
	local row = bit32.rshift(model.numleafs + 7, 3)
	local out = buffer.create(row)
	local visdata = model.brush.visdata
	if leaf.num == 0 or leaf.visofs == -1 or not visdata then
		buffer.fill(out, 0, 0xff, row) -- mod_novis: all visible
		return out
	end
	local inpos = leaf.visofs
	local outpos = 0
	while outpos < row do
		local b = buffer.readu8(visdata, inpos)
		if b ~= 0 then
			buffer.writeu8(out, outpos, b)
			inpos += 1
			outpos += 1
		else
			local c = buffer.readu8(visdata, inpos + 1)
			inpos += 2
			outpos += c -- run of zero bytes (buffer is zero-initialized)
		end
	end
	return out
end

return bsp
