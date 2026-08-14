local AAF_SM = AAF_SM or {}

AAF_SM.cfg = AAF_SM.cfg or { rescan_interval_ticks = 8 }
AAF_SM.initialised      = AAF_SM.initialised or false
AAF_SM.bm               = AAF_SM.bm or nil
AAF_SM.tick_counter     = AAF_SM.tick_counter or 0
AAF_SM.last_rescan_tick = AAF_SM.last_rescan_tick or 0
AAF_SM.unit_list        = AAF_SM.unit_list or {}
AAF_SM.units_by_key     = AAF_SM.units_by_key or {}
AAF_SM.units_by_unit    = AAF_SM.units_by_unit or {}

-- 安全取单位坐标(x,z)，兼容多种 pos 接口
function AAF_SM.safe_unit_pos(u)
  if not u then return nil, nil end
  local pos
  if u.position then
    pos = u:position()
  elseif u.unit then
    local inner = u:unit()
    pos = inner and inner.position and inner:position() or nil
  end
  if not pos then return nil, nil end

  local x = pos.get_x and pos:get_x() or pos.x and pos:x() or nil
  local z = pos.get_z and pos:get_z() or pos.z and pos:z() or nil
  if x and z then return x, z end

  if pos.get_xz then return pos:get_xz() end
  return nil, nil
end

-- 单位稳定标识(优先 unique_ui_id)
function AAF_SM.unit_key(u)
  if not u then return "nil" end
  if u.unique_ui_id then return "u#"..tostring(u:unique_ui_id()) end
  if u.unit_key then return tostring(u:unit_key()) end
  if u.name then return tostring(u:name()) end
  return tostring(u)
end

-- 单位是否溃逃/破碎/死亡
function AAF_SM.unit_is_routing(u)
  if not u then return true end
  if u.is_shattered and u:is_shattered() then return true end
  if u.is_routing and u:is_routing() then return true end
  if u.routing and u:routing() then return true end
  if u.is_dead and u:is_dead() then return true end
  return false
end

local function detect_character_flags(u)
  local is_lord = (u.is_lord and u:is_lord()) or (u.is_general and u:is_general()) or false
  local is_hero = (u.is_hero and u:is_hero()) or (u.is_officer and u:is_officer()) or false
  return (is_lord or is_hero), is_lord, is_hero
end

local function is_flying(u)
  if not u then return false end
  return (u.is_currently_flying and u:is_currently_flying()) or (u.is_flying and u:is_flying()) or false
end

-- 判定玩家单位：优先 is_player_controlled，回退到联盟索引比对
local function is_player_unit(u)
  if not u then return false end
  if u.is_player_controlled then
    local pc = u:is_player_controlled()
    return pc and true or false
  end
  local bm_obj = AAF_SM.bm or bm
  if bm_obj and bm_obj.get_player_alliance and u.alliance_index then
    local pal = bm_obj:get_player_alliance()
    if pal and pal.index then
      return u:alliance_index() == pal:index()
    end
  end
  return false
end

local function safe_alliance_index(alliance)
  if not alliance then return nil end
  if alliance.index then return alliance:index() end
  if alliance.id then return alliance:id() end
  return nil
end

local function for_each_alliance(cb)
  if not AAF_SM.bm then return end
  if AAF_SM.bm.alliances then
    local alliances = AAF_SM.bm:alliances()
    for i = 1, alliances:count() do
      local ali = alliances:item(i)
      if ali then cb(ali) end
    end
    return
  end
  local pal = AAF_SM.bm:get_player_alliance()
  if pal then cb(pal) end
  local eal = AAF_SM.bm:get_non_player_alliance()
  if eal then cb(eal) end
end

-- 全量扫描单位，建立 udata 缓存
local function rescan_all_units()
  if not AAF_SM.bm then return end

  local unit_list, units_by_key, units_by_unit =
    AAF_SM.unit_list, AAF_SM.units_by_key, AAF_SM.units_by_unit

  local pal = AAF_SM.bm:get_player_alliance()
  local player_alliance_index = pal and safe_alliance_index(pal) or nil

  local function scan_alliance(alliance)
    if not alliance then return end
    local ali_idx = safe_alliance_index(alliance)
    local armies = alliance:armies()
    if not armies then return end

    for a = 1, armies:count() do
      local army = armies:item(a)
      if army then
        local units = army:units()
        if units then
          for i = 1, units:count() do
            local u = units:item(i)
            if u then
              local key = AAF_SM.unit_key(u)
              local udata = units_by_key[key]
              local is_player_alliance = player_alliance_index and ali_idx == player_alliance_index or false

              if udata then
                -- 已缓存：刷新引用
                if udata.dead then
                  udata.dead, udata.alive, udata.routing = false, true, false
                end
                udata.unit, udata.army, udata.alliance = u, army, alliance
                udata.alliance_index = ali_idx
                udata.is_player_alliance = is_player_alliance
                units_by_unit[u] = udata
              else
                -- 新单位
                local x, z = AAF_SM.safe_unit_pos(u)
                local routing = AAF_SM.unit_is_routing(u)
                local player_ctrl = is_player_unit(u)
                local side_tag = player_ctrl and "player" or (is_player_alliance and "ally" or "enemy")
                local side = side_tag == "enemy" and "ai" or side_tag
                local char, lord, hero = detect_character_flags(u)
                local missile_range = u.missile_range and u:missile_range() or nil
                if type(missile_range) ~= "number" then missile_range = nil end

                udata = {
                  unit=u, army=army, alliance=alliance, alliance_index=ali_idx, key=key,
                  is_player_alliance=is_player_alliance, is_player_unit=player_ctrl,
                  side_tag=side_tag, side=side,
                  x=x, z=z, alive=(x~=nil), dead=(x==nil), routing=routing,
                  is_flying=is_flying(u), is_character=char, is_lord=lord, is_hero=hero,
                  missile_range=missile_range,
                }
                unit_list[#unit_list+1] = udata
                units_by_key[key] = udata
                units_by_unit[u] = udata
              end
            end
          end
        end
      end
    end
  end

  for_each_alliance(scan_alliance)
end

function AAF_SM.init_from_bm(bm_obj)
  if AAF_SM.initialised then return end
  AAF_SM.bm = bm_obj or bm
  AAF_SM.unit_list, AAF_SM.units_by_key, AAF_SM.units_by_unit = {}, {}, {}
  AAF_SM.tick_counter, AAF_SM.last_rescan_tick = 0, 0
  AAF_SM.initialised = true
  rescan_all_units()
end

function AAF_SM.get_udata(unit)
  return AAF_SM.units_by_unit[unit]
end

function AAF_SM.set_controller(unit, who)
  local udata = AAF_SM.units_by_unit[unit]
  if udata then udata.controller = who or "ai" end
end

-- 每 tick 刷新：按 rescan_interval_ticks 周期全量重扫，其余 tick 仅更新坐标/状态
function AAF_SM.update(tick)
  if not AAF_SM.initialised then return end
  AAF_SM.tick_counter = tick or AAF_SM.tick_counter + 1

  local interval = AAF_SM.cfg.rescan_interval_ticks or 8
  if AAF_SM.tick_counter == 1 or AAF_SM.tick_counter - AAF_SM.last_rescan_tick >= interval then
    rescan_all_units()
    AAF_SM.last_rescan_tick = AAF_SM.tick_counter
  end

  for _, udata in ipairs(AAF_SM.unit_list) do
    if udata then
      local u = udata.unit
      if not u or AAF_SM.unit_is_routing(u) then
        -- 溃逃≠死亡：保留在索敌候选池(低 tier)
        udata.routing, udata.alive, udata.dead = true, true, false
      else
        local x, z = AAF_SM.safe_unit_pos(u)
        if not x then
          udata.alive, udata.dead, udata.routing = false, true, true
        else
          udata.alive, udata.dead, udata.routing = true, false, false
          udata.x, udata.z = x, z
          udata.is_flying = is_flying(u)
        end
      end
    end
  end
end

rawset(_G, "AAF_SM", AAF_SM)
return AAF_SM
