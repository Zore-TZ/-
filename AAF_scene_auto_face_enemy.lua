local scene = {
  id               = "auto_face_enemy",
  priority         = 1000,
  session_priority = 1000,
  enabled          = true,
}
local M = {}
M.SCENE_ID = scene.id
-- 模块配置
M.CFG = {
  -- 开关与快捷键
  ENABLED                    = true,
  TOGGLE_SHORTCUT            = "camera_bookmark_view11",
  TOGGLE_DIAGNOSE            = true,
  TOGGLE_AUTO_BIND           = false,
  -- 扫描节流
  SCAN_INTERVAL_MS           = 1000,
  MAX_UNITS_PER_SCAN         = 40,
  UNIT_COOLDOWN_MS           = 2500,
  ATTACK_REISSUE_CD_MS       = 5000,
  PERIODIC_SWEEP_MS          = 5000,
  -- 索敌范围
  MIN_ENEMY_RANGE_M          = 10,
  MAX_ENEMY_RANGE_M          = 400,
  THREAT_WEIGHT_DISTANCE     = 1.0,
  THREAT_WEIGHT_FLYING       = 0.3,
  -- 射击弧与射程
  FIRE_ARC_TOLERANCE_DEG     = 90,
  RANGE_MARGIN_RATIO         = 0.9,
  RANGE_MARGIN_MIN_M         = 10,
  -- 朝向辅助
  ENABLE_FACE_ONLY           = true,
  FACE_COOLDOWN_MS           = 2000,
  FACE_RANGE_MULT            = 1.6,
  FACE_SEARCH_RANGE_M        = 300,
  -- 攻击约束
  REQUIRE_STATIC_STRIKE      = true,
  SKIP_FAR_TARGETS           = true,
  COMMAND_RANGE_FRACTION     = 0.4,
  COMMAND_MAX_RANGE_M        = 100,
  CHASE_GUARD_ENABLED        = true,
  -- 调试
  DEBUG_LEVEL                = 1,
  DEBUG_MAX_LINES_PER_TICK   = 200,
  DEBUG_PIN                  = false,
  DEBUG_BALLISTIC            = false,
  -- 行为模式要求
  REQUIRE_FIRE_AT_WILL       = true,
  REQUIRE_DEFEND_MODE        = true,
  REQUIRE_LINE_OF_SIGHT      = true,
  -- 弹道单位
  PREFER_BALLISTIC_WHEN_RESTRICTED = true,
  BALLISTIC_UNIT_KEYS        = {},
  BALLISTIC_RANGE_MIN        = 300,
  BALLISTIC_USE_RANGE_HEURISTIC = true,
  BALLISTIC_FORCE_HIGH_ARC   = true,
  -- 目标黑名单
  SCRIPT_TARGET_BL_MS        = 15000,
  -- 玩家控制
  PLAYER_CMD_GRACE_MS        = 6000,
  PLAYER_CMD_MOVE_MS         = 15000,
  -- 移动判定
  ORDER_SETTLE_MS            = 1000,
  MOVE_OK_EPS_M             = 8,
  HOLD_RETRY_MS             = 5000,
  -- 移动黑名单与超时
  MOVE_UNIT_BLACKLIST_STREAK = 2,
  UNIT_BLACKLIST_MS         = 15000,
  MOVE_STREAK_RESET_MS      = 15000,
  TARGET_STALE_MS            = 15000,
  -- 驻防回拉
  ENABLE_HOME_PULLBACK       = false,
  HOME_REFRESH_EPS           = 1.5,
  HOME_DRIFT_CAP_M           = 4,
  -- 近战规避
  ENABLE_MELEE_AVOIDANCE     = false,
  MELEE_AVOID_RADIUS_M       = 45,
  -- 溃逃过滤
  ROUT_BREAK_CASTES          = { melee_infantry = true, missile_infantry = true },
  ROUT_KEEP_MULTI_HP_GT      = 0.10,
  -- 溃逃远程仍可攻击的血量阈值（高于此值的溃逃远程优先于普通近战）
  ROUT_REMOTE_HP_THRESHOLD   = 0.30,
  -- 玩家英雄/领主排除：不接管、不下发攻击/转身/halt
  SKIP_PLAYER_CHARACTERS     = true,
}
-- 安全调用对象方法，失败返回 nil
function M.safe_call(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, ret = pcall(fn, obj, ...)
  if not ok then return nil end
  return ret
end
-- 任意值转为布尔
function M.safe_bool(v)
  if type(v) == "boolean" then return v end
  return v and true or false
end
-- 安全获取单位坐标
function M.safe_unit_pos(u)
  if not u then return nil, nil end
  if AAF_SM and AAF_SM.safe_unit_pos then
    local x, z = AAF_SM.safe_unit_pos(u)
    if x and z then return x, z end
  end
  local pos = M.safe_call(u, "position")
  if not pos then return nil, nil end
  local x = M.safe_call(pos, "get_x") or M.safe_call(pos, "x")
  local z = M.safe_call(pos, "get_z") or M.safe_call(pos, "z")
  if x and z then return x, z end
  return nil, nil
end
-- 生成单位稳定唯一键
function M.unit_stable_key(unit, udata)
  if udata and type(udata.key) == "string" and udata.key ~= "" then return udata.key end
  local n = M.safe_call(unit, "unique_ui_id")
  if n ~= nil then return "u#"..tostring(n) end
  return tostring(unit)
end
-- 调试日志输出
function M.dbg(api, st, level, msg)
  if (M.CFG.DEBUG_LEVEL or 0) < level then return end
  st._dbg_lines = (st._dbg_lines or 0) + 1
  if st._dbg_lines > (M.CFG.DEBUG_MAX_LINES_PER_TICK or 200) then return end
  if rawget(_G, "aaf_debug") then
    aaf_debug("["..M.SCENE_ID.."] "..tostring(msg))
  elseif api and api.debug then
    pcall(function() api.debug(scene, tostring(msg)) end)
  end
end
-- 时间戳兜底（毫秒）
function M.now_ms_fallback()
  return math.floor((os.clock() or 0) * 1000)
end
-- 两点距离平方
function M.dist2(ax, az, bx, bz)
  local dx, dz = ax - bx, az - bz
  return dx*dx + dz*dz
end
-- 两点距离
function M.dist(ax, az, bx, bz)
  return math.sqrt(M.dist2(ax, az, bx, bz))
end
-- 获取单位朝向角度
function M.get_bearing_deg(unit)
  local b = M.safe_call(unit, "bearing")
  if type(b) ~= "number" then return nil end
  b = b % 360
  if b < 0 then b = b + 360 end
  return b
end
-- 计算从一点指向另一点的方位角
function M.bearing_to_point(shx, shz, ex, ez)
  local dx, dz = ex - shx, ez - shz
  if dx == 0 and dz == 0 then return nil end
  local deg = (math.atan(dx, dz) * 180 / math.pi) % 360
  if deg < 0 then deg = deg + 360 end
  return deg
end
-- 角度差归一化到 [-180,180]
function M.angle_diff_180(a, b)
  local d = (a - b) % 360
  if d > 180 then d = d - 360 end
  if d < -180 then d = d + 360 end
  return d
end
-- 判断是否为远程单位
function M.is_ranged_unit(unit, udata)
  if udata and type(udata.missile_range) == "number" and udata.missile_range > 0 then return true end
  if not unit then return false end
  local sa = M.safe_call(unit, "starting_ammo")
  if type(sa) == "number" and sa > 4 then return true end
  local r = M.safe_call(unit, "missile_range")
  return type(r) == "number" and r > 0
end
-- 判断是否有弹药
function M.has_ammo(unit)
  if not unit then return true end
  local a = M.safe_call(unit, "ammo_left")
  return type(a) ~= "number" or a > 0
end
-- 判断是否处于近战
function M.is_in_melee(unit)
  local f = M.safe_call(unit, "is_in_melee")
  return type(f) == "boolean" and f or false
end
-- 判断是否快速移动中
function M.is_moving_fast(unit)
  local f = M.safe_call(unit, "is_moving_fast")
  return type(f) == "boolean" and f or false
end
-- 判断是否移动中
function M.is_moving(unit)
  local m = M.safe_call(unit, "is_moving")
  if type(m) == "boolean" then return m end
  return M.is_moving_fast(unit)
end
-- 引擎层移动状态查询（nil 表示未知）
function M.engine_is_moving(unit)
  local m = M.safe_call(unit, "is_moving")
  if type(m) == "boolean" then return m end
  local f = M.safe_call(unit, "is_moving_fast")
  if type(f) == "boolean" then return f end
  return nil
end
-- 检测附近是否有近战威胁
function M.near_enemy_melee_threat(unit, ctx, radius)
  if not unit or not ctx then return false end
  local sx, sz = M.safe_unit_pos(unit)
  if not sx then return false end
  local enemies = ctx.units and ctx.units.by_side and ctx.units.by_side.ai
  if not enemies then return false end
  local r = radius or 45
  for _, ed in ipairs(enemies) do
    if ed and ed.unit and ed.alive and not ed.routing and ed.x and ed.z then
      if M.dist(sx, sz, ed.x, ed.z) <= r then return true end
    end
  end
  return false
end
-- 获取单位当前血量比例（0-1），失败返回 nil
function M.unit_hp_ratio(unit)
  if not unit then return nil end
  -- 优先使用引擎比例 API
  local pct = M.safe_call(unit, "percentage_proportion_of_initial_men_alive")
  if type(pct) == "number" and pct >= 0 and pct <= 1 then return pct end
  -- 回退：存活人数 / 初始人数
  local alive = M.safe_call(unit, "number_of_men_alive")
  local init = M.safe_call(unit, "initial_number_of_men")
  if type(alive) == "number" and type(init) == "number" and init > 0 then
    local r = alive / init
    if r >= 0 and r <= 1 then return r end
  end
  return nil
end
-- 引擎实时校验单位是否仍在溃逃（不检查 is_leaving_battle，避免恢复后返回原位被误判）
function M.is_unit_routing_now(unit)
  if not unit then return true end
  if unit.is_routing and unit:is_routing() then return true end
  if unit.routing and unit:routing() then return true end
  if unit.is_shattered and unit:is_shattered() then return true end
  if unit.is_dead and unit:is_dead() then return true end
  return false
end
-- 引擎实时校验单位是否为领主/英雄（character/单体）
-- WH3 battle 沙盒中 is_character/is_lord/is_hero 等 API 普遍返回 nil，
-- 改用 type 字段含 "_cha_"（character 标识）+ initial_number_of_men<=1 判定
function M.is_unit_character(unit)
  if not unit then return false end
  -- type 字段含 "_cha_" 表示 character（英雄/领主）
  local ut = M.safe_call(unit, "type")
  if type(ut) == "string" and ut:find("_cha_") then return true end
  -- 兜底：单体（初始人数<=1）视为领主/英雄
  local n = M.safe_call(unit, "initial_number_of_men")
  if type(n) == "number" and n <= 1 then return true end
  return false
end
-- 判断玩家单位是否应被 MOD 接管跳过（领主/英雄/单体）
function M.should_skip_control(unit, udata)
  if not M.CFG.SKIP_PLAYER_CHARACTERS then return false end
  if not unit then return true end
  if udata and (udata.is_lord or udata.is_hero) then return true end
  if M.is_unit_character(unit) then return true end
  return false
end
-- 推断目标单位类型分类
function M.get_target_caste(unit)
  if not unit then return "unknown" end
  local uk = M.safe_call(unit, "type")
  if type(uk) ~= "string" then return "unknown" end
  uk = uk:lower()
  local is_ranged = M.is_ranged_unit(unit, nil)
  local init = M.safe_call(unit, "initial_number_of_men")
  local single = type(init) == "number" and init <= 1
  if M.safe_call(unit, "is_character") == true then return "lord" end
  if uk:find("infantry") then
    if single then return "monstrous_infantry" end
    return is_ranged and "missile_infantry" or "melee_infantry"
  end
  if uk:find("cavalry") then
    return is_ranged and "missile_cavalry" or "melee_cavalry"
  end
  if uk:find("monster") then return "monster" end
  if uk:find("war_machine") or uk:find("artillery") then return "warmachine" end
  if uk:find("chariot") then return "chariot" end
  if uk:find("beast") or uk:find("dog") then return "war_beast" end
  return "unknown"
end
-- 获取单位射程
function M.get_missile_range(unit, udata)
  if udata then
    local r = udata.missile_range_final or udata.missile_range or udata.range
    if type(r) == "number" and r > 0 and r <= 1000 then return r end
  end
  local r = M.safe_call(unit, "missile_range")
  if type(r) == "number" and r > 0 and r <= 1000 then return r end
  return nil
end
-- 判断目标是否在射程内（含边距）
function M.is_target_in_range(shooter, target, shooter_udata)
  if not target then return false end
  local range = M.get_missile_range(shooter, shooter_udata)
  if type(range) ~= "number" then return false end
  local eng = M.safe_call(shooter, "unit_in_range", target)
  if eng == false then return false end
  local sx, sz = M.safe_unit_pos(shooter)
  local tx, tz = M.safe_unit_pos(target)
  if not sx or not tx then return false end
  local C = M.CFG
  local cap = math.min(range * (C.RANGE_MARGIN_RATIO or 0.9), range - (C.RANGE_MARGIN_MIN_M or 10))
  if cap < 1 then cap = range end
  return M.dist(sx, sz, tx, tz) <= cap
end
-- 判断目标是否在射击弧内
function M.is_target_in_fire_arc(shooter, target)
  if not shooter or not target then return false end
  local arc = M.safe_call(shooter, "in_arc_of_fire", target)
  if type(arc) == "boolean" then return arc end
  local cof = M.safe_call(shooter, "can_open_fire_on", target)
  if type(cof) == "boolean" then return cof end
  local sx, sz = M.safe_unit_pos(shooter)
  local tx, tz = M.safe_unit_pos(target)
  local b = M.get_bearing_deg(shooter)
  if not (sx and tx and b) then return nil end
  local tb = M.bearing_to_point(sx, sz, tx, tz)
  if not tb then return nil end
  return math.abs(M.angle_diff_180(b, tb)) <= (M.CFG.FIRE_ARC_TOLERANCE_DEG or 90)
end
-- 判断当前是否可开火
function M.can_open_fire_now(shooter, target)
  if not shooter or not target then return false end
  local v = M.safe_call(shooter, "can_open_fire_on", target)
  if type(v) == "boolean" then return v end
  return nil
end
-- 单位当前位置到指令目标点的距离
function M.ordered_move_dist(unit)
  local op = M.safe_call(unit, "ordered_position")
  if not op then return nil end
  local ox = M.safe_call(op, "get_x") or M.safe_call(op, "x")
  local oz = M.safe_call(op, "get_z") or M.safe_call(op, "z")
  if type(ox) ~= "number" or type(oz) ~= "number" then return nil end
  local cx, cz = M.safe_unit_pos(unit)
  if not cx or not cz then return nil end
  return M.dist(cx, cz, ox, oz)
end
-- 综合判断目标是否可射击
function M.is_target_shootable(shooter, target, shooter_udata, shooter_ballistic)
  if not M.is_target_in_range(shooter, target, shooter_udata) then return false end
  if shooter_ballistic then return true end
  if not M.is_target_visible(shooter, target) then return false end
  if M.can_open_fire_now(shooter, target) == false then return false end
  return true
end
-- 综合判断是否有射击解（射程+可见+弧内）
function M.firing_solution(shooter, target, shooter_udata, shooter_ballistic)
  if not shooter or not target then return false end
  if not M.is_target_shootable(shooter, target, shooter_udata, shooter_ballistic) then return false end
  local arc = M.is_target_in_fire_arc(shooter, target)
  if arc == false then return false end
  return true
end
-- 缓存玩家联盟对象
local _player_alliance = nil
function M.get_player_alliance_obj()
  if _player_alliance ~= nil then return _player_alliance end
  local ok, a = pcall(function() return bm:get_player_alliance() end)
  _player_alliance = (ok and a) or false
  return _player_alliance
end
-- 判断目标对玩家是否可见
function M.is_target_visible(shooter, target)
  if not target then return false end
  local alli = M.get_player_alliance_obj()
  if alli == false then return true end
  local vis = M.safe_call(target, "is_visible_to_alliance", alli)
  return type(vis) ~= "boolean" or vis
end
-- 判断是否为弹道（抛射）单位
function M.is_ballistic_shooter(unit, udata)
  if not unit then return false end
  local C = M.CFG
  if udata and udata.is_ballistic == true then return true end
  if udata and type(udata.key) == "string" and C.BALLISTIC_UNIT_KEYS and C.BALLISTIC_UNIT_KEYS[udata.key] then return true end
  for _, m in ipairs({ "is_artillery", "is_siege", "is_ballistic", "uses_ballistic_ammo", "is_artillery_unit" }) do
    local v = M.safe_call(unit, m)
    if type(v) == "boolean" then return v end
  end
  if M.is_ranged_unit(unit, udata) then
    local proj = M.safe_call(unit, "primary_projectile") or M.safe_call(unit, "get_projectile")
    if proj then
      local pb = M.safe_call(proj, "is_ballistic")
      if type(pb) == "boolean" then return pb end
    end
    local sa = M.safe_call(unit, "starting_ammo")
    if type(sa) == "table" then
      for _, a in ipairs(sa) do
        local p = a and (a.projectile or a.missile or a.proj)
        if p then
          local b = M.safe_call(p, "is_ballistic")
          if type(b) == "boolean" then return b end
        end
      end
    end
  end
  if C.BALLISTIC_USE_RANGE_HEURISTIC and M.is_ranged_unit(unit, udata) then
    local r = M.get_missile_range(unit, udata)
    if r and r >= (C.BALLISTIC_RANGE_MIN or 190) then return true end
  end
  return false
end
-- 强制弹道单位使用高弹道
function M.ensure_high_arc(unit, udata)
  if not unit or not M.CFG.BALLISTIC_FORCE_HIGH_ARC then return nil end
  if not M.is_ballistic_shooter(unit, udata) then return nil end
  for _, m in ipairs({ "force_use_high_arc", "enable_high_arc", "set_high_arc" }) do
    local fn = unit[m]
    if type(fn) == "function" then
      pcall(fn, unit, m == "enable_high_arc" and nil or true)
      return m
    end
  end
  return nil
end
-- 判断行为模式是否可用
function M.behaviour_usable(unit, key)
  local b = M.safe_call(unit, "can_use_behaviour", key)
  return type(b) ~= "boolean" or b
end
-- 判断自由开火是否开启
function M.is_fire_at_will_on(unit, udata)
  local b = M.safe_call(unit, "is_behaviour_active", "fire_at_will")
  if type(b) == "boolean" then return b end
  return udata and (udata.fire_at_will == true or udata.fire_at_will_on == true) or false
end
-- 判断驻防模式是否开启
function M.is_defend_on(unit, udata)
  local b = M.safe_call(unit, "is_behaviour_active", "defend")
  if type(b) == "boolean" then return b end
  return udata and (udata.defend == true or udata.guard_mode == true) or false
end
-- 检查所需行为模式是否满足
function M.modes_satisfied(unit, udata)
  local C = M.CFG
  if C.REQUIRE_FIRE_AT_WILL then
    if not M.behaviour_usable(unit, "fire_at_will") or not M.is_fire_at_will_on(unit, udata) then return false end
  end
  if C.REQUIRE_DEFEND_MODE then
    if not M.behaviour_usable(unit, "defend") or not M.is_defend_on(unit, udata) then return false end
  end
  return true
end
-- 判断单位是否具备行为能力
function M.behaviour_capable(unit)
  return M.behaviour_usable(unit, "fire_at_will")
end
-- 注册玩家指令监听，记录玩家操作时间
M._player_cmd_real_ms = M._player_cmd_real_ms or {}
function M.ensure_player_cmd_watch()
  if not M._player_cmd_watch_ok then
    if type(bm) == "table" and type(bm.register_player_unit_command) == "function" then
      pcall(function()
        bm:register_player_unit_command(function(context)
          local u = nil
          pcall(function() u = context:unit() end)
          if not u then pcall(function() u = context.unit end) end
          if not u then pcall(function() u = context:commanded_unit() end) end
          if not u then return end
          -- 部署阶段拖拽不算战斗控制，跳过
          local phase = nil
          if bm.get_current_phase_name then pcall(function() phase = bm:get_current_phase_name() end) end
          if phase == "Deployed" then return end
          local t = (bm.time and bm:time() or 0) * 1000
          local key = M.unit_stable_key(u)
          M._player_cmd_real_ms[key] = t
          M.dbg(M._api, M._st, 1, "PLAYER_CMD key="..tostring(key).." t="..tostring(t).." phase="..tostring(phase))
          if M._api and M._st and M._scene then
            pcall(function() M._release_hold(M._api, M._st, M._scene, u, key) end)
          end
        end)
        M._player_cmd_watch_ok = true
      end)
    end
  end
  M.register_toggle_listener()
end
-- 判断玩家是否正在控制该单位
function M.is_player_controlling(ukey, grace_ms, unit)
  grace_ms = grace_ms or (M.CFG.PLAYER_CMD_GRACE_MS or 6000)
  local t = M._player_cmd_real_ms[ukey]
  if not t then return false end
  local now = (bm and bm.time and bm:time() or 0) * 1000
  if (now - t) < grace_ms then
    if unit and (not M.engine_is_moving(unit)) and (not M.is_in_melee(unit)) then
      return false
    end
    return true
  end
  local move_ms = M.CFG.PLAYER_CMD_MOVE_MS or 15000
  if unit and (now - t) < move_ms and M.engine_is_moving(unit) then
    return true
  end
  return false
end
-- 获取单位当前有效脚本目标
function M.effective_target(st, ukey, unit)
  local t = st and st._script_target and st._script_target[ukey]
  if t and not M.safe_bool(M.safe_call(t, "is_null_interface")) then
    local alive = M.safe_call(t, "number_of_men_alive")
    if type(alive) ~= "number" or alive > 0 then return t end
  end
  return nil
end
-- 判断目标是否为"低价值溃逃"单位（tier 0）：溃逃且非领主/英雄且非高血量远程
-- 用于切换/清空逻辑：仅低价值溃逃才强制清空当前目标
function M.is_low_value_rout(unit, udata, C)
  if not unit then return false end
  local routing = udata and udata.routing
  if not routing then return false end
  -- 领主/英雄溃逃仍有价值（tier 4）
  if udata and (udata.is_lord or udata.is_hero) then return false end
  -- 溃逃远程：血量高于阈值仍有价值（tier 3）
  if M.is_ranged_unit(unit, udata) then
    local hp = M.unit_hp_ratio(unit)
    if hp and hp > (C.ROUT_REMOTE_HP_THRESHOLD or 0.30) then return false end
  end
  return true
end
-- 计算敌方威胁评分
-- 索敌优先级（tier）：
--   5 未溃逃远程
--   4 领主/英雄（含溃逃）
--   3 溃逃但血量超过 ROUT_REMOTE_HP_THRESHOLD 的远程
--   2 未溃逃普通目标 + 在射击弧内
--   1 未溃逃普通目标 + 不在射击弧内
--   0 溃逃普通单位（含近战溃逃、低血量远程溃逃）
function M.compute_threat_score(shooter_x, shooter_z, enemy, enemy_udata, in_fire_arc)
  if not enemy then return -1 end
  local ex, ez
  if enemy_udata and enemy_udata.x and enemy_udata.z then
    ex, ez = enemy_udata.x, enemy_udata.z
  else
    local pos = M.safe_call(enemy, "position")
    if pos and type(pos) == "table" then
      ex = M.safe_call(pos, "get_x") or M.safe_call(pos, "x")
      ez = M.safe_call(pos, "get_z") or M.safe_call(pos, "z")
    end
  end
  if not ex then return -1 end
  local d = M.dist(shooter_x, shooter_z, ex, ez)
  local C = M.CFG
  if d < C.MIN_ENEMY_RANGE_M or d > C.MAX_ENEMY_RANGE_M then return -1 end
  local routing = enemy_udata and enemy_udata.routing
  local is_char = enemy_udata and (enemy_udata.is_lord or enemy_udata.is_hero)
  local is_ranged = M.is_ranged_unit(enemy, enemy_udata)
  local tier
  if is_ranged and not routing then tier = 5
  elseif is_char then tier = 4
  elseif is_ranged and routing then
    -- 溃逃远程：血量高于阈值仍值得攻击，否则落入最低优先级
    local hp = M.unit_hp_ratio(enemy)
    tier = (hp and hp > (C.ROUT_REMOTE_HP_THRESHOLD or 0.30)) and 3 or 0
  elseif (not is_ranged) and (not routing) then
    tier = (in_fire_arc == true) and 2 or 1
  else tier = 0 end
  local score = tier * 1000
  score = score + ((C.MAX_ENEMY_RANGE_M - d) / C.MAX_ENEMY_RANGE_M) * C.THREAT_WEIGHT_DISTANCE * 100
  if enemy_udata and enemy_udata.is_flying then
    score = score + C.THREAT_WEIGHT_FLYING * 50
  end
  return score, ex, ez, d
end
-- 判断目标是否在射手黑名单中
function M.is_target_blacklisted(st, shooter_key, target)
  local tbl = st._script_target_bl and st._script_target_bl[shooter_key]
  if not tbl then return false end
  return tbl[M.unit_stable_key(target)] ~= nil
end
-- 清理过期黑名单
function M.cleanup_target_blacklist(st, now_ms)
  if not st._script_target_bl then return end
  for _, tbl in pairs(st._script_target_bl) do
    for tk, expire in pairs(tbl) do
      if now_ms >= expire then tbl[tk] = nil end
    end
  end
end
-- 为射手寻找最佳敌方目标
-- 不再按射击弧分桶，统一按 compute_threat_score 选最高分（射击弧状态已纳入 tier）
function M.find_best_enemy(shooter, shooter_udata, ctx, api, st)
  if not shooter or not shooter_udata then return nil end
  local sx, sz = M.safe_unit_pos(shooter)
  if not sx then return nil end
  local C = M.CFG
  local shooter_key = M.unit_stable_key(shooter, shooter_udata)
  local shooter_ballistic = M.is_ballistic_shooter(shooter, shooter_udata)
  local enemies = ctx.units.by_side.ai
  local best = { score = -1 }
  local ranged_in, melee_in = 0, 0
  for _, eu in ipairs(enemies) do
    if eu and eu.unit and not M.is_target_blacklisted(st, shooter_key, eu.unit) then
      local vis_ok = shooter_ballistic or (not C.REQUIRE_LINE_OF_SIGHT) or M.is_target_visible(shooter, eu.unit)
      if vis_ok then
        local in_arc = M.is_target_in_fire_arc(shooter, eu.unit)
        local score, ex, ez, d = M.compute_threat_score(sx, sz, eu.unit, eu, in_arc)
        if score >= 0 and M.is_target_in_range(shooter, eu.unit, shooter_udata) then
          -- 不再用 firing_solution 硬性过滤：射程内按 score 选最高，射击弧外的高价值目标也会被选中以触发转身
          if score > best.score then
            best.score, best.udata, best.ex, best.ez, best.dist, best.in_arc = score, eu, ex, ez, d, (in_arc == true)
          end
          if M.is_ranged_unit(eu.unit, eu) then ranged_in = ranged_in + 1 else melee_in = melee_in + 1 end
        end
      end
    end
  end
  local chosen = best
  local ballistic_override = false
  -- 弹道单位无目标时放宽限制重选
  if not chosen.udata and shooter_ballistic and C.PREFER_BALLISTIC_WHEN_RESTRICTED then
    local bb = { score = -1 }
    for _, eu in ipairs(enemies) do
      if eu and eu.unit and not M.is_target_blacklisted(st, shooter_key, eu.unit) then
        local in_arc = M.is_target_in_fire_arc(shooter, eu.unit)
        local score, ex, ez, d = M.compute_threat_score(sx, sz, eu.unit, eu, in_arc)
        if score >= 0 and M.is_target_in_range(shooter, eu.unit, shooter_udata) and score > bb.score then
          bb.score, bb.udata, bb.ex, bb.ez, bb.dist, bb.in_arc = score, eu, ex, ez, d, (in_arc == true)
        end
      end
    end
    if bb.udata then chosen, ballistic_override = bb, true end
  end
  if chosen.udata then
    if shooter_ballistic and not M.is_target_visible(shooter, chosen.udata.unit) then
      ballistic_override = true
    end
    return chosen.udata.unit, chosen.ex, chosen.ez, chosen.dist, chosen.score, ballistic_override, ranged_in, melee_in, chosen.in_arc
  end
  return nil
end
-- 寻找朝向辅助目标
-- 统一按 compute_threat_score 选最高分；领主/英雄(tier 4)即使不在射击弧内也会被选中以触发转身
function M.find_face_target(shooter, shooter_udata, ctx, api, st)
  if not shooter or not shooter_udata then return nil end
  local sx, sz = M.safe_unit_pos(shooter)
  if not sx then return nil end
  local shooter_key = M.unit_stable_key(shooter, shooter_udata)
  local C = M.CFG
  local shooter_ballistic = M.is_ballistic_shooter(shooter, shooter_udata)
  local range = M.get_missile_range(shooter, shooter_udata)
  local face_range = (range and range > 0) and (range * (C.FACE_RANGE_MULT or 1.6)) or (C.FACE_SEARCH_RANGE_M or 300)
  local best = { score = -1 }
  for _, eu in ipairs(ctx.units.by_side.ai) do
    if eu and eu.unit and not M.is_target_blacklisted(st, shooter_key, eu.unit) then
      local vis_ok = shooter_ballistic or (not C.REQUIRE_LINE_OF_SIGHT) or M.is_target_visible(shooter, eu.unit)
      if vis_ok then
        local in_arc = M.is_target_in_fire_arc(shooter, eu.unit)
        local score, ex, ez, d = M.compute_threat_score(sx, sz, eu.unit, eu, in_arc)
        if score >= 0 and d and d <= face_range then
          if score > best.score then
            best.score, best.unit, best.ex, best.ez, best.dist = score, eu.unit, ex, ez, d
          end
        end
      end
    end
  end
  return best.unit or nil, best.ex, best.ez, best.dist, best.score
end
-- 对单位执行一次朝向转向
function M.issue_face_once(scene, api, st, unit, unit_udata, target_unit, ex, ez, now_ms)
  if not (scene and unit and target_unit) then return false end
  if M.should_skip_control(unit, unit_udata) then return false end
  if M.is_moving_fast(unit) then return false end
  if M.is_in_melee(unit) then return false end
  local C = M.CFG
  local ukey = M.unit_stable_key(unit, unit_udata)
  local now = now_ms or 0
  if st._face_cd and st._face_cd[ukey] and now < st._face_cd[ukey] then return false end
  local applied = false
  pcall(function()
    if unit.turn_to_face and ex and ez then
      unit:turn_to_face(v(ex, 0, ez))
      applied = true
    end
  end)
  if not applied then
    if not st._diag_face_api then
      st._diag_face_api = true
      M.dbg(api, st, 1, "FACE_ONLY_API_MISSING unit_has_ttf="..tostring(not not (unit and unit.turn_to_face)))
    end
    return false
  end
  st._face_cd = st._face_cd or {}
  st._face_cd[ukey] = now + (C.FACE_COOLDOWN_MS or 2000)
  M.dbg(api, st, 1, "FACE_ONLY unit="..tostring(ukey).." target="..tostring(M.unit_stable_key(target_unit)))
  return true
end
-- 查询对同一目标的攻击重发冷却剩余
function M.attack_target_remaining_cd(st, ukey, target_unit, now_ms, C)
  if not (C and C.ATTACK_REISSUE_CD_MS and C.ATTACK_REISSUE_CD_MS > 0) then return 0 end
  local tcd = st._attack_target_cd and st._attack_target_cd[ukey] and st._attack_target_cd[ukey][M.unit_stable_key(target_unit)]
  if not tcd then return 0 end
  local rem = tcd - now_ms
  return rem > 0 and rem or 0
end
-- 下发一次攻击命令并登记状态
function M.issue_attack_once(api, scene, session, shooter_unit, target_unit, shooter_udata, now_ms, rpos, rb, rw, st)
  if not session or not session.controller or not target_unit or not shooter_unit then
    if session and api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_ABORT") end) end
    return false
  end
  if M.should_skip_control(shooter_unit, shooter_udata) then
    if api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "SKIP_CHARACTER") end) end
    return false
  end
  if M.is_moving_fast(shooter_unit) then
    if api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_UNIT_MOVING_FAST") end) end
    return false
  end
  if M.is_in_melee(shooter_unit) then
    if session and api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_IN_MELEE") end) end
    return false
  end
  if M.is_ranged_unit(shooter_unit, nil) and not M.has_ammo(shooter_unit) then
    if api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_NO_AMMO") end) end
    return false
  end
  if M.is_ranged_unit(shooter_unit, nil) and not M.is_target_in_range(shooter_unit, target_unit) then
    if api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_OUT_OF_RANGE") end) end
    return false
  end
  if M.CFG.REQUIRE_DEFEND_MODE and M.is_defend_on(shooter_unit, shooter_udata) then
    if not M.is_target_in_range(shooter_unit, target_unit, shooter_udata) then
      if session and api.is_session_owner(scene, session) then
        pcall(function() api.release_session(session, "DEFEND_NO_MOVE") end)
      end
      return false
    end
    local arc = M.is_target_in_fire_arc(shooter_unit, target_unit)
    if arc == false then
      if session and api.is_session_owner(scene, session) then
        pcall(function() api.release_session(session, "DEFEND_OUT_OF_ARC") end)
      end
      return false
    end
  end
  local uc = session.controller
  local ok, err = pcall(function()
    -- 固定 allow_move=false：禁止 WH3 自动追击/接近移动
    uc:attack_unit(target_unit, false, false)
    if uc.change_behaviour_active then
      uc:change_behaviour_active("fire_at_will", true)
      uc:change_behaviour_active("fire_at_will", false)
      uc:change_behaviour_active("fire_at_will", true)
    end
    return true
  end)
  -- 攻击后释放控制，保持攻击命令；移动由 monitor_script_movement 的 CHASE_GUARD 处理
  pcall(function() if uc.release_control then uc:release_control() end end)
  if api.is_session_owner(scene, session) then pcall(function() api.release_session(session, "ATTACK_ISSUED") end) end
  if not ok then
    if st then
      st._last_attack_err = st._last_attack_err or {}
      st._last_attack_err[M.unit_stable_key(shooter_unit)] = tostring(err)
    end
    return false
  end
  local ukey = M.unit_stable_key(shooter_unit)
  if now_ms and st then
    st._home_pos = st._home_pos or {}
    local hx, hz = M.safe_unit_pos(shooter_unit)
    if hx and hz and not M.is_moving_fast(shooter_unit) then
      local old = st._home_pos[ukey]
      if not old or M.dist(old.x, old.z, hx, hz) <= (M.CFG.HOME_REFRESH_EPS or 1.5) then
        st._home_pos[ukey] = { x = hx, z = hz }
      end
    end
    st._script_target = st._script_target or {}
    st._script_target[ukey] = target_unit
    st._last_known_target = st._last_known_target or {}
    st._last_known_target[ukey] = target_unit
    st._target_since_ms = st._target_since_ms or {}
    st._target_since_ms[ukey] = now_ms
    st._unit_by_key = st._unit_by_key or {}
    st._unit_by_key[ukey] = shooter_unit
    st._anchor_pos = st._anchor_pos or {}
    if not st._anchor_pos[ukey] then st._anchor_pos[ukey] = { x = hx, z = hz } end
    st._move_base = st._move_base or {}
    st._move_base[ukey] = nil
    st._script_pending = st._script_pending or {}
    st._script_pending[ukey] = {
      unit = shooter_unit, target = target_unit, issued_ms = now_ms,
      rpos = rpos, anchor_x = hx, anchor_z = hz,
    }
    st._attack_target_cd = st._attack_target_cd or {}
    st._attack_target_cd[ukey] = st._attack_target_cd[ukey] or {}
    st._attack_target_cd[ukey][M.unit_stable_key(target_unit)] = now_ms + (M.CFG.ATTACK_REISSUE_CD_MS or 5000)
    -- 记录延迟 halt 时间：2秒后执行 halt 防止追击
    st._halt_after_ms = st._halt_after_ms or {}
    st._halt_after_ms[ukey] = now_ms + 2000
  end
  return true
end
-- 释放脚本对单位的接管
function M._release_hold(api, st, scene, unit, ukey)
  local s = api.get_session_for_unit(unit)
  if s then
    if s.controller then
      pcall(function() if s.controller.halt then s.controller:halt() end end)
      pcall(function() if s.controller.release_control then s.controller:release_control() end end)
      pcall(function() if s.controller.clear_all then s.controller:clear_all() end end)
    end
    if (not scene) or api.is_session_owner(scene, s) then
      pcall(function() api.release_session(s, "NO_RANGED_IN_RANGE") end)
    end
  end
  if st and st._ranged_hold then st._ranged_hold[ukey] = nil end
  if st and st._script_target then st._script_target[ukey] = nil end
  if st and st._move_base then st._move_base[ukey] = nil end
  if st and st._halt_after_ms then st._halt_after_ms[ukey] = nil end
end
-- 判断 mod 是否启用
function M.is_mod_enabled()
  if M._mod_enabled == nil then M._mod_enabled = (M.CFG.ENABLED ~= false) end
  return M._mod_enabled
end
-- 设置 mod 启用状态
function M.set_mod_enabled(on, api, st, scene)
  api = api or M._api
  st = st or M._st
  scene = scene or M._scene
  M._mod_enabled = on and true or false
  M.dbg(api, st, 1, "MOD_TOGGLE set enabled="..tostring(M._mod_enabled))
end
-- 重置所有被脚本接管的单位
function M.reset_all_units(api, st, scene)
  if not (api and st and scene) then return end
  if st._unit_by_key then
    for k, u in pairs(st._unit_by_key) do
      pcall(function()
        if u and not M.safe_bool(M.safe_call(u, "is_null_interface")) then
          -- 仅处理已接管的 session，避免误接管正常单位
          local session = api.get_session_for_unit(u)
          if session and session.controller then
            local uc = session.controller
            -- 恢复行为 -> halt -> 释放控制 -> 清空
            pcall(function() if uc.change_behaviour_active then
              uc:change_behaviour_active("fire_at_will", true)
              uc:change_behaviour_active("defend", true)
            end end)
            pcall(function() if uc.halt then uc:halt() end end)
            pcall(function() if uc.release_control then uc:release_control() end end)
            pcall(function() if uc.clear_all then uc:clear_all() end end)
          end
          if session and ((not scene) or api.is_session_owner(scene, session)) then
            pcall(function() if api.release_session then api.release_session(session, "TOGGLE_RESET") end end)
          end
        end
      end)
    end
  end
  st._script_target = nil
  st._script_pending = nil
  st._target_blacklist = nil
  st._unit_blacklist = nil
  st._move_base = nil
  st._face_cd = nil
  st._cooldowns = nil
  st._target_since_ms = nil
  st._unit_by_key = nil
  st._hold_until_ms = nil
  st._will_move_streak = nil
  st._halt_after_ms = nil
  M.dbg(api, st, 1, "MOD_TOGGLE reset_all_units done")
end
-- 注册快捷键开关监听
function M.register_toggle_listener()
  if M._toggle_watch_ok then return end
  if type(core) ~= "table" or type(core.add_listener) ~= "function" then
    M.dbg(M._api, M._st, 1, "MOD_TOGGLE core_unavailable")
    return
  end
  local last_diag = -99999
  local function get_shortcut_name(context)
    return context and context.string
  end
  core:add_listener(
    "aaf_mod_toggle",
    "ShortcutTriggered",
    function(context)
      local name = get_shortcut_name(context)
      if type(name) ~= "string" or name == "" then return false end
      if M.CFG.TOGGLE_DIAGNOSE then
        local now = M.now_ms_fallback()
        if now - last_diag > 300 then
          last_diag = now
          M.dbg(M._api, M._st, 1, "SHORTCUT_PRESS name="..name)
        end
      end
      if M.CFG.TOGGLE_AUTO_BIND and (not M.CFG.TOGGLE_SHORTCUT or M.CFG.TOGGLE_SHORTCUT == "") then
        if name == "escape" or name == "toggle_escape" then return false end
        M.CFG.TOGGLE_SHORTCUT = name
        M.CFG.TOGGLE_AUTO_BIND = false
        M.dbg(M._api, M._st, 1, "TOGGLE_AUTOBOUND to="..name)
        return true
      end
      return name == M.CFG.TOGGLE_SHORTCUT
    end,
    function(context)
      local on = not M.is_mod_enabled()
      M.set_mod_enabled(on, M._api, M._st, M._scene)
      -- 切换时统一重置单位状态
      M.reset_all_units(M._api, M._st, M._scene)
      if on and M._st then
        -- 开启后立即触发下次索敌
        M._st._last_scan_ms = 0
        M._st._sweep_last_ms = 0
      end
      M.dbg(M._api, M._st, 1, "TOGGLE_FIRED enabled="..tostring(M.is_mod_enabled()))
    end,
    true
  )
  M._toggle_watch_ok = true
  M.dbg(M._api, M._st, 1, "MOD_TOGGLE listener_registered shortcut="..tostring(M.CFG.TOGGLE_SHORTCUT))
end
-- 对单位下发停止命令
function M.issue_stop(api, scene, unit)
  if not (api and unit) then return false end
  local session = api.get_session_for_unit(unit)
  if not session and scene and api.request_session then
    session = api.request_session(scene, unit, { role = "stop" })
  end
  if not (session and session.controller) then return false end
  if scene and api.is_session_owner and not api.is_session_owner(scene, session) then return false end
  local uc = session.controller
  local ok = pcall(function()
    if uc.halt then uc:halt() end
    if uc.change_behaviour_active then
      uc:change_behaviour_active("fire_at_will", true)
    end
  end)
  pcall(function() if uc.release_control then uc:release_control() end end)
  if (not scene) or api.is_session_owner(scene, session) then
    pcall(function() api.release_session(session, "STOP_ISSUED") end)
  end
  return ok
end
-- 驻防回拉与射程溢出处理
function M.try_pullback(api, st, ukey, rec, unit, C, now_ms, ctx, scene)
  local home = st._home_pos and st._home_pos[ukey]
  if home and C.ENABLE_HOME_PULLBACK then
    local cx, cz = M.safe_unit_pos(unit)
    if cx and cz then
      local drift = M.dist(home.x, home.z, cx, cz)
      if drift > (C.HOME_DRIFT_CAP_M or 4) then
        local stopped = M.issue_stop(api, scene, unit)
        M.dbg(api, st, 1, "MONITOR: unit="..ukey.." HOME_DRIFT_CAP -> halt="..tostring(stopped))
        return true
      end
    end
  end
  local tgt = rec and rec.target
  if tgt and not M.safe_bool(M.safe_call(tgt, "is_null_interface")) then
    local range = M.get_missile_range(unit, nil)
    local sx, sz = M.safe_unit_pos(unit)
    local tx, tz = M.safe_unit_pos(tgt)
    if type(range) == "number" and sx and tx and M.dist(sx, sz, tx, tz) > range - 5 then
      local new_tgt, switched = M.requeue_target(api, st, ukey, unit, tgt, now_ms, C, ctx, scene)
      if new_tgt then
        if switched then
          M.dbg(api, st, 1, "MONITOR: unit="..ukey.." RANGE_CAP -> blacklist_cur15s + requeue_new="..tostring(M.unit_stable_key(new_tgt)))
        else
          M.dbg(api, st, 1, "MONITOR: unit="..ukey.." RANGE_CAP -> reengage_cur="..tostring(M.unit_stable_key(new_tgt)))
        end
      else
        M.dbg(api, st, 1, "MONITOR: unit="..ukey.." RANGE_CAP -> no_target")
      end
      return true
    end
  end
  return false
end
-- 重新排队目标（黑名单当前目标后另寻）
function M.requeue_target(api, st, ukey, unit, cur_tgt, now_ms, C, ctx, scene)
  local udata = ctx.units and ctx.units.by_unit and ctx.units.by_unit[unit]
  if not udata and AAF_SM and AAF_SM.get_udata then pcall(function() udata = AAF_SM.get_udata(unit) end) end
  local enemy_list = ctx.units and ctx.units.by_side and ctx.units.by_side.ai
  if not (udata and enemy_list) then return nil end
  if M.should_skip_control(unit, udata) then return nil end
  local shooter_ballistic = M.is_ballistic_shooter(unit, udata)
  local function lock(t)
    local session = api.get_session_for_unit(unit) or (scene and api.request_session and api.request_session(scene, unit, { role = "requeue" }))
    if not (session and (not scene or api.is_session_owner(scene, session))) then return nil end
    local rpos = M.safe_call(unit, "ordered_position")
    local rb   = M.safe_call(unit, "ordered_bearing")
    local rw   = M.safe_call(unit, "ordered_width")
    if not M.issue_attack_once(api, scene, session, unit, t, udata, now_ms, rpos, rb, rw, st) then return nil end
    local hx, hz = M.safe_unit_pos(unit)
    if hx then
      if st._anchor_pos then st._anchor_pos[ukey] = { x = hx, z = hz } end
      if st._home_pos then st._home_pos[ukey] = { x = hx, z = hz } end
    end
    return t
  end
  local black_tgt = cur_tgt
  local black_key = nil
  if black_tgt and not M.safe_bool(M.safe_call(black_tgt, "is_null_interface")) then
    black_key = M.unit_stable_key(black_tgt)
    st._script_target_bl = st._script_target_bl or {}
    local tbl = st._script_target_bl[ukey] or {}
    st._script_target_bl[ukey] = tbl
    tbl[black_key] = now_ms + (C.SCRIPT_TARGET_BL_MS or 15000)
  end
  local cand = M.find_best_enemy(unit, udata, ctx, api, st)
  if cand and (not black_key or M.unit_stable_key(cand) ~= black_key) then
    -- 目标不在射击弧内时先转身，不调用 lock（issue_attack_once 会因 DEFEND_OUT_OF_ARC 失败）
    local cand_in_arc = M.is_target_in_fire_arc(unit, cand)
    if cand_in_arc ~= true and not shooter_ballistic then
      local cx, cz = M.safe_unit_pos(cand)
      if cx and cz then M.issue_face_once(scene, api, st, unit, udata, cand, cx, cz, now_ms) end
      return nil
    end
    local r = lock(cand)
    if r then return r, true end
    return nil
  end
  M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
  local hold = st._hold_until_ms or {}
  st._hold_until_ms = hold
  hold[ukey] = now_ms + (C.HOLD_RETRY_MS or 5000)
  return nil
end
-- 清除单位攻击状态并释放控制
function M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
  local has_session = api.get_session_for_unit(unit)
  st._script_target = st._script_target or {}
  st._script_target[ukey] = nil
  st._script_pending = st._script_pending or {}
  st._script_pending[ukey] = nil
  st._move_base = st._move_base or {}
  st._move_base[ukey] = nil
  local session = has_session or (scene and api.request_session and api.request_session(scene, unit, { role = "clear" }))
  if session and session.controller then
    local uc = session.controller
    pcall(function() if uc.halt then uc:halt() end end)
    pcall(function() if uc.release_control then uc:release_control() end end)
    pcall(function() if uc.clear_all then uc:clear_all() end end)
  end
  if session and (not scene or api.is_session_owner(scene, session)) then
    pcall(function() if api.release_session then api.release_session(session, "NO_VISIBLE_TARGET") end end)
  end
end
-- 监控脚本接管单位的移动，处理玩家抢占与守卫拉回
function M.monitor_script_movement(api, st, now_ms, C, ctx, scene)
  st._script_target = st._script_target or {}
  st._unit_by_key = st._unit_by_key or {}
  st._anchor_pos = st._anchor_pos or {}
  st._move_base = st._move_base or {}
  if not M._api_probed then
    for _, u in pairs(st._unit_by_key) do
      if u then
        M._api_probed = true
        local a, c, im = "nil", "nil", "nil"
        pcall(function() a = type(u.in_arc_of_fire) end)
        pcall(function() c = type(u.can_open_fire_on) end)
        pcall(function() im = type(u.is_moving) end)
        M.dbg(api, st, 1, "API_PROBE: in_arc_of_fire="..a.." can_open_fire_on="..c
          .." is_moving="..im.." engine_moving="..tostring(M.engine_is_moving(u))
          .." bearing="..tostring(M.get_bearing_deg(u))
          .." alliance_index="..tostring(M.safe_call(u, "alliance_index"))
          .." ordered_dist="..tostring(M.ordered_move_dist(u)))
        break
      end
    end
  end
  for ukey, unit in pairs(st._unit_by_key) do
    if unit and not M.should_skip_control(unit) then
      local hold_until = (st._hold_until_ms or {})[ukey]
      if hold_until and now_ms < hold_until then
      else
        -- 延迟 halt：攻击下发2秒后执行 halt，防止追击移动，halt 后重新转身面向目标
        local halt_after = (st._halt_after_ms or {})[ukey]
        if halt_after and now_ms >= halt_after then
          st._halt_after_ms[ukey] = nil
          local halt_session = api.get_session_for_unit(unit) or (scene and api.request_session and api.request_session(scene, unit, { role = "halt_after" }))
          if halt_session and halt_session.controller then
            local hc = halt_session.controller
            pcall(function() if hc.halt then hc:halt() end end)
            -- halt 后重新转身面向目标，避免 halt 影响朝向
            local tgt = st._script_target[ukey]
            if tgt then
              local tx, tz = M.safe_unit_pos(tgt)
              if tx and tz then
                pcall(function() if unit.turn_to_face then unit:turn_to_face(v(tx, 0, tz)) end end)
              end
            end
            pcall(function() if hc.release_control then hc:release_control() end end)
          end
          if halt_session and ((not scene) or api.is_session_owner(scene, halt_session)) then
            pcall(function() if api.release_session then api.release_session(halt_session, "HALT_AFTER_2S") end end)
          end
          M.dbg(api, st, 1, "HALT_AFTER_2S unit="..tostring(ukey))
        end
        if M.is_in_melee(unit) then
          M._release_hold(api, st, scene, unit, ukey)
        else
          local tgt = st._script_target[ukey]
      local routing_now = AAF_SM and AAF_SM.unit_is_routing and AAF_SM.unit_is_routing(unit) or false
      local no_claim = (not st._script_target[ukey]) and (not (st._script_pending and st._script_pending[ukey]))
      local pmove_fb = false
      do
        local lo = st._last_order_ms and st._last_order_ms[ukey]
        local no_recent = (not lo) or (now_ms - lo > (C.ORDER_SETTLE_MS or 1000))
        local bx, bz = nil, nil
        if st._move_base and st._move_base[ukey] then bx = st._move_base[ukey].x; bz = st._move_base[ukey].z end
        local cx, cz = M.safe_unit_pos(unit)
        local disp = (bx and cx) and M.dist(bx, bz, cx, cz) or 0
        pmove_fb = M.engine_is_moving(unit) and no_recent and disp > (C.MOVE_OK_EPS_M or 8) and (not M.is_in_melee(unit))
      end
      -- 玩家抢占或自行漂移则释放控制
      if (not routing_now) and (M.is_player_controlling(ukey, nil, unit) or (no_claim and M._player_cmd_real_ms[ukey] and M.engine_is_moving(unit)) or pmove_fb) then
        st._script_pending = st._script_pending or {}
        st._script_pending[ukey] = nil
        if st._script_target_bl then st._script_target_bl[ukey] = nil end
        M._release_hold(api, st, scene, unit, ukey)
        M.dbg(api, st, 1, "MONITOR: unit="..ukey.." PLAYER_CMD -> release to player")
        M._player_cmd_real_ms[ukey] = (bm and bm.time and bm:time() or 0) * 1000
      else
        local cx, cz = M.safe_unit_pos(unit)
        local pend = st._script_pending and st._script_pending[ukey]
        local settling = pend and pend.issued_ms and (now_ms - pend.issued_ms) < (C.ORDER_SETTLE_MS or 3000)
        local em = M.engine_is_moving(unit)
        if settling then
          if cx and cz and not st._move_base[ukey] then
            st._move_base[ukey] = { x = cx, z = cz }
          end
        else
          if em ~= true and cx and cz then
            st._anchor_pos[ukey] = { x = cx, z = cz }
          end
          if cx and cz and not st._move_base[ukey] then
            st._move_base[ukey] = { x = cx, z = cz }
          end
        end
        local guarded = false
        -- 守卫拉回：漂移过多则停止/重排队/黑名单
        if (not settling) and C.CHASE_GUARD_ENABLED and tgt and not M.safe_bool(M.safe_call(tgt, "is_null_interface")) then
          local base = st._move_base[ukey]
          local moved = nil
          if base and cx and cz then moved = M.dist(base.x, base.z, cx, cz) end
          local will_move = type(moved) == "number" and moved > (C.MOVE_OK_EPS_M or 8)
          if will_move then
            st._will_move_streak = st._will_move_streak or {}
            st._will_move_streak[ukey] = (st._will_move_streak[ukey] or 0) + 1
            st._move_last_ms = st._move_last_ms or {}
            st._move_last_ms[ukey] = now_ms
          end
          local streak = (st._will_move_streak and st._will_move_streak[ukey]) or 0
          if will_move and streak >= (C.MOVE_UNIT_BLACKLIST_STREAK or 2) then
            M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
            local hold = st._hold_until_ms or {}
            st._hold_until_ms = hold
            hold[ukey] = now_ms + (C.UNIT_BLACKLIST_MS or 15000)
            st._will_move_streak[ukey] = 0
            st._move_base[ukey] = nil
            M.dbg(api, st, 1, "MONITOR: unit="..ukey.." MOVE unit_blacklist15s moved="..string.format("%.2f", moved)
              .." om="..tostring(M.ordered_move_dist(unit)).." STREAK="..tostring(streak))
            guarded = true
          elseif will_move then
            local stopped = M.issue_stop(api, scene, unit)
            local om = M.ordered_move_dist(unit)
            local nt = M.requeue_target(api, st, ukey, unit, tgt, now_ms, C, ctx, scene)
            st._move_base[ukey] = nil
            M.dbg(api, st, 1, "MONITOR: unit="..ukey.." will_move moved="..string.format("%.2f", moved).." om="..tostring(om)
              .." -> halt="..tostring(stopped).." + blacklist_target15s + "..(nt and ("requeue_new="..tostring(M.unit_stable_key(nt))) or "hold_faw"))
            guarded = true
          end
        end
        if not guarded then
          st._will_move_streak = st._will_move_streak or {}
          local last = st._move_last_ms and st._move_last_ms[ukey]
          if last and (now_ms - last) > (C.MOVE_STREAK_RESET_MS or 15000) then
            st._will_move_streak[ukey] = 0
          end
          local rec = (st._script_pending and st._script_pending[ukey]) or { target = tgt, unit = unit, rpos = nil, issued_ms = now_ms }
          M.try_pullback(api, st, ukey, rec, unit, C, now_ms, ctx, scene)
        end
      end
      end
    end
  end
end
end
-- 收集所有远程单位
function M.collect_ranged_units(ctx)
  local out = {}
  if not ctx or not ctx.units or not ctx.units.by_side then return out end
  for side, list in pairs(ctx.units.by_side) do
    if list then
      for _, udata in ipairs(list) do
        -- 跳过领主/英雄单位（引擎实时校验）
        if udata and udata.unit and M.is_ranged_unit(udata.unit, udata) and not M.is_unit_character(udata.unit) then
          out[#out+1] = { udata = udata, side = side }
        end
      end
    end
  end
  return out
end
-- 为周期扫描寻找目标
-- 统一按 compute_threat_score 选最高分（射击弧状态已纳入 tier），branch 仅用于日志标注
function M.find_target_for_sweep(shooter, shooter_udata, enemies, api, st, C)
  if not shooter or not shooter_udata or not enemies then return nil end
  local sx, sz = M.safe_unit_pos(shooter)
  if not sx then return nil end
  local shooter_ballistic = M.is_ballistic_shooter(shooter, shooter_udata)
  local shooter_key = M.unit_stable_key(shooter, shooter_udata)
  local best = { score = -1 }
  for _, eu in ipairs(enemies) do
    if eu and eu.unit and not M.is_target_blacklisted(st, shooter_key, eu.unit) then
      local vis_ok = shooter_ballistic or (not C.REQUIRE_LINE_OF_SIGHT) or M.is_target_visible(shooter, eu.unit)
      if vis_ok then
        local in_arc = M.is_target_in_fire_arc(shooter, eu.unit)
        local score, ex, ez, d = M.compute_threat_score(sx, sz, eu.unit, eu, in_arc)
        if score >= 0 and M.is_target_in_range(shooter, eu.unit, shooter_udata) then
          if score > best.score then
            best = { score = score, unit = eu.unit, ex = ex, ez = ez, dist = d, tag = (in_arc == true) and "arc" or "range" }
          end
        end
      end
    end
  end
  if best.unit then return best.unit, best.ex, best.ez, best.dist, best.score, best.tag end
  return nil
end
-- 周期扫描中检查单个单位状态并补发攻击
function M.sweep_unit_status_check(api, st, ctx, now_ms, C, item, scene)
  local udata = item.udata
  local unit = udata and udata.unit
  if not (unit and udata) then return end
  local ukey = M.unit_stable_key(unit, udata)
  if M.is_player_controlling(ukey, nil, unit) then return end
  if M.should_skip_control(unit, udata) then return end
  if not M.modes_satisfied(unit, udata) then return end
  if not M.has_ammo(unit) then return end
  if item.side ~= "player" then return end
  if M.is_in_melee(unit) then return end
  local hold_until = (st._hold_until_ms or {})[ukey]
  if hold_until and now_ms < hold_until then return end
  local enemy_list = ctx.units and ctx.units.by_side and ctx.units.by_side.ai
  if not enemy_list then return end
  local shooter_ballistic = M.is_ballistic_shooter(unit, udata)
  local cur_tgt = M.effective_target(st, ukey, unit)
  if cur_tgt == nil then
    local enemy, ex, ez, edist, _, branch = M.find_target_for_sweep(unit, udata, enemy_list, api, st, C)
    if not (enemy and ex) then return end
    -- 不在射击弧内时先转身，等下次扫描进入射击弧后再攻击
    if branch ~= "arc" and not shooter_ballistic then
      M.issue_face_once(scene, api, st, unit, udata, enemy, ex, ez, now_ms)
      return
    end
    if C.REQUIRE_STATIC_STRIKE and not M.firing_solution(unit, enemy, udata, shooter_ballistic) then return end
    if M.attack_target_remaining_cd(st, ukey, enemy, now_ms, C) > 0 then return end
    local session = api.get_session_for_unit(unit) or api.request_session(scene, unit, { role = "sweep_auto_attack" })
    if not (session and api.is_session_owner(scene, session)) then return end
    local rpos = M.safe_call(unit, "ordered_position")
    local rb   = M.safe_call(unit, "ordered_bearing")
    local rw   = M.safe_call(unit, "ordered_width")
    if M.issue_attack_once(api, scene, session, unit, enemy, udata, now_ms, rpos, rb, rw, st) then
      st._cooldowns = st._cooldowns or {}
      st._cooldowns[ukey] = now_ms + C.UNIT_COOLDOWN_MS
      M.dbg(api, st, 1, string.format("SWEEP_ACQUIRE unit=%s dist=%.1f branch=%s", tostring(ukey), edist or 0, tostring(branch)))
    end
    return
  end
  local shootable = M.is_target_shootable(unit, cur_tgt, udata, shooter_ballistic)
  local stalled = false
  local ammo_now = M.safe_call(unit, "ammo_left")
  if type(ammo_now) == "number" and ammo_now >= 0 and ammo_now <= 9000 then
    st._sweep_ammo = st._sweep_ammo or {}
    local prev = st._sweep_ammo[ukey]
    if prev and prev > 0 and ammo_now >= prev then stalled = true end
    st._sweep_ammo[ukey] = ammo_now
  end
  if shootable == false or stalled then
    local enemy, ex, ez, edist, _, branch = M.find_target_for_sweep(unit, udata, enemy_list, api, st, C)
    if not (enemy and ex) or enemy == cur_tgt then
      return
    end
    if C.REQUIRE_STATIC_STRIKE and not M.firing_solution(unit, enemy, udata, shooter_ballistic) then return end
    if M.attack_target_remaining_cd(st, ukey, enemy, now_ms, C) > 0 then return end
    local session = api.get_session_for_unit(unit) or api.request_session(scene, unit, { role = "sweep_auto_attack" })
    if not (session and api.is_session_owner(scene, session)) then return end
    local rpos = M.safe_call(unit, "ordered_position")
    local rb   = M.safe_call(unit, "ordered_bearing")
    local rw   = M.safe_call(unit, "ordered_width")
    if M.issue_attack_once(api, scene, session, unit, enemy, udata, now_ms, rpos, rb, rw, st) then
      st._cooldowns = st._cooldowns or {}
      st._cooldowns[ukey] = now_ms + C.UNIT_COOLDOWN_MS
      M.dbg(api, st, 1, string.format("SWEEP_REASSIGN unit=%s dist=%.1f branch=%s reason=%s", tostring(ukey), edist or 0, tostring(branch), stalled and "no_fire" or "not_shootable"))
    end
  end
end
-- 周期性扫描所有远程单位补索敌
function M.periodic_targeting_sweep(api, st, ctx, now_ms, C, scene)
  local units = M.collect_ranged_units(ctx)
  M.dbg(api, st, 1, string.format("SWEEP_RUN collected=%d", #units))
  for _, item in ipairs(units) do
    M.sweep_unit_status_check(api, st, ctx, now_ms, C, item, scene)
  end
end
-- 主循环：每 tick 监控移动、清理黑名单、周期扫描与节流索敌
function M.on_tick(scene, ctx, api)
  local C = M.CFG
  local st = api.scene_state(scene)
  M._api, M._scene, M._st = api, scene, st
  M.ensure_player_cmd_watch()
  st._dbg_lines = 0
  if not C.ENABLED then return end
  if not M.is_mod_enabled() then return end
  st._script_pending = st._script_pending or {}
  st._script_target = st._script_target or {}
  local now_ms = ctx.time_ms or M.now_ms_fallback()
  M.monitor_script_movement(api, st, now_ms, C, ctx, scene)
  M.cleanup_target_blacklist(st, now_ms)
  local sweep_due = (st._sweep_last_ms == nil) or (now_ms - (st._sweep_last_ms or 0) >= C.PERIODIC_SWEEP_MS)
  if sweep_due then
    st._sweep_last_ms = now_ms
    M.periodic_targeting_sweep(api, st, ctx, now_ms, C, scene)
  end
  st._last_scan_ms = st._last_scan_ms or 0
  if now_ms - st._last_scan_ms < C.SCAN_INTERVAL_MS then return end
  st._last_scan_ms = now_ms
  st._cooldowns = st._cooldowns or {}
  st._last_bearing = st._last_bearing or {}
  st._last_order_ms = st._last_order_ms or {}
  local player_units = ctx.units.by_side.player
  local processed = 0
  for _, udata in ipairs(player_units) do
    if processed >= C.MAX_UNITS_PER_SCAN then break end
    local unit = udata and udata.unit
    local ukey = unit and M.unit_stable_key(unit, udata)
    if ukey and M.is_ranged_unit(unit, udata) then
      if not (st._diag_seen and st._diag_seen[ukey]) then
        st._diag_seen = st._diag_seen or {}
        st._diag_seen[ukey] = true
        -- 诊断 character API 返回值，确认英雄/领主判定
        local ic = M.safe_call(unit, "is_character")
        local il = M.safe_call(unit, "is_lord")
        local ih = M.safe_call(unit, "is_hero")
        local ig = M.safe_call(unit, "is_general")
        local io = M.safe_call(unit, "is_officer")
        local se = M.safe_call(unit, "is_single_entity")
        local init = M.safe_call(unit, "initial_number_of_men")
        local ut = M.safe_call(unit, "type")
        M.dbg(api, st, 1, string.format("DIAG_SEEN unit=%s char=%s lord=%s hero=%s gen=%s off=%s single=%s init=%s type=%s",
          tostring(ukey), tostring(ic), tostring(il), tostring(ih), tostring(ig), tostring(io), tostring(se), tostring(init), tostring(ut)))
      end
    end
    repeat
      local hold_until = (st._hold_until_ms or {})[ukey]
      if hold_until and now_ms < hold_until then break end
      if M.is_player_controlling(ukey, nil, unit) then
        st._script_pending = st._script_pending or {}; st._script_pending[ukey] = nil
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      if not (udata and udata.alive and unit and ukey) then
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      -- 状态机标记 routing 时，用引擎 API 二次校验：已恢复（rally）的单位允许接管
      if udata.routing and M.is_unit_routing_now(unit) then
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      -- 不接管领主/英雄单位
      if M.should_skip_control(unit, udata) then
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      if not M.is_ranged_unit(unit, udata) then break end
      local shooter_ballistic = M.is_ballistic_shooter(unit, udata)
      if C.DEBUG_BALLISTIC then
        M.dbg(api, st, 1, string.format("BALLISTIC_PROBE unit=%s key=%s range=%.0f ballistic=%s",
          tostring(ukey), tostring(udata.key), M.get_missile_range(unit, udata) or -1, tostring(shooter_ballistic)))
      end
      if C.BALLISTIC_FORCE_HIGH_ARC then M.ensure_high_arc(unit, udata) end
      if C.ENABLE_MELEE_AVOIDANCE and M.near_enemy_melee_threat(unit, ctx, C.MELEE_AVOID_RADIUS_M or 45) then
        st._script_pending = st._script_pending or {}; st._script_pending[ukey] = nil
        break
      end
      local current_tgt = M.effective_target(st, ukey, unit)
      st._last_known_target = st._last_known_target or {}
      st._target_since_ms = st._target_since_ms or {}
      if current_tgt ~= st._last_known_target[ukey] then
        st._last_known_target[ukey] = current_tgt
        st._target_since_ms[ukey] = now_ms
        st._no_fire_since_ms = st._no_fire_since_ms or {}; st._no_fire_since_ms[ukey] = nil
      end
      local target_age_ms = now_ms - (st._target_since_ms[ukey] or now_ms)
      local has_tgt = current_tgt ~= nil
      local in_melee_now = M.is_in_melee(unit)
      st._script_target = st._script_target or {}
      local target_stale = has_tgt and target_age_ms > (C.TARGET_STALE_MS or 20000) and not in_melee_now
      local no_fire_stale = false
      if has_tgt and not in_melee_now then
        local cur_ammo = M.safe_call(unit, "ammo_left")
        if type(cur_ammo) == "number" and cur_ammo >= 0 and cur_ammo <= 9000 then
          st._last_ammo = st._last_ammo or {}
          st._no_fire_since_ms = st._no_fire_since_ms or {}
          if st._last_ammo[ukey] == nil then st._last_ammo[ukey] = cur_ammo end
          local fired = cur_ammo < (st._last_ammo[ukey] or cur_ammo)
          st._last_ammo[ukey] = cur_ammo
          if fired then st._no_fire_since_ms[ukey] = nil
          elseif st._no_fire_since_ms[ukey] == nil then st._no_fire_since_ms[ukey] = now_ms end
          local nf_age = st._no_fire_since_ms[ukey] and (now_ms - st._no_fire_since_ms[ukey]) or 0
          no_fire_stale = nf_age > (C.TARGET_STALE_MS or 20000)
        end
      end
      local cur_visible = has_tgt and M.is_target_visible(unit, current_tgt) or false
      local cur_in_range = has_tgt and M.is_target_in_range(unit, current_tgt, udata) or false
      local cur_vision_ok = cur_visible or shooter_ballistic
      local cur_routing = has_tgt and M.is_unit_routing_now(current_tgt) or false
      local cur_low_rout = has_tgt and M.is_low_value_rout(current_tgt, (ctx.units.by_unit and ctx.units.by_unit[current_tgt]) or (AAF_SM and AAF_SM.get_udata and AAF_SM.get_udata(current_tgt)), C) or false
      local cur_blacklisted = has_tgt and M.is_target_blacklisted(st, ukey, current_tgt)
      local should_reeval = (not has_tgt) or target_stale or no_fire_stale or (not cur_vision_ok) or (not cur_in_range) or cur_routing or cur_blacklisted
      if has_tgt and not should_reeval then break end
      if not M.modes_satisfied(unit, udata) then
        st._diag_modes_ts = st._diag_modes_ts or {}
        if not st._diag_modes_ts[ukey] or now_ms - st._diag_modes_ts[ukey] >= 10000 then
          st._diag_modes_ts[ukey] = now_ms
          M.dbg(api, st, 1, string.format("DIAG_MODES_OFF unit=%s faw=%s defend=%s", tostring(ukey), tostring(M.is_fire_at_will_on(unit, udata)), tostring(M.is_defend_on(unit, udata))))
        end
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      if M.is_player_controlling(ukey, nil, unit) then
        M._release_hold(api, st, scene, unit, ukey)
        break
      end
      if M.is_in_melee(unit) then
        M._release_hold(api, st, scene, unit, ukey)
        st._script_pending = st._script_pending or {}; st._script_pending[ukey] = nil
        break
      end
      local enemy, ex, ez, edist, enemy_score, _, _, _, enemy_in_arc = M.find_best_enemy(unit, udata, ctx, api, st)
      if not enemy then
        -- 无射程内目标：清空低价值溃逃 + find_face_target 在更大范围搜索转身
        if cur_low_rout and has_tgt then
          M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
          M.dbg(api, st, 1, "ROUT_CLEAR unit="..tostring(ukey).." no_replacement_target")
        end
        if C.ENABLE_FACE_ONLY then
          local f_unit, f_ex, f_ez = M.find_face_target(unit, udata, ctx, api, st)
          if f_unit then M.issue_face_once(scene, api, st, unit, udata, f_unit, f_ex, f_ez, now_ms) end
        end
        break
      end
      -- 射程内但不在射击弧：转向目标，等下次扫描进入射击弧后再攻击
      if not enemy_in_arc and not shooter_ballistic then
        if C.ENABLE_FACE_ONLY then
          M.issue_face_once(scene, api, st, unit, udata, enemy, ex, ez, now_ms)
        end
        break
      end
      -- 在射击弧内：检查可射击性（可见性等）
      local enemy_can_fire = M.is_target_shootable(unit, enemy, udata, shooter_ballistic)
      if not enemy_can_fire then
        if cur_low_rout and has_tgt then
          M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
          M.dbg(api, st, 1, "ROUT_CLEAR unit="..tostring(ukey).." no_replacement_target")
        end
        if C.ENABLE_FACE_ONLY then
          local f_unit, f_ex, f_ez = M.find_face_target(unit, udata, ctx, api, st)
          if f_unit then M.issue_face_once(scene, api, st, unit, udata, f_unit, f_ex, f_ez, now_ms) end
        end
        break
      end
      local cur_score = -1
      if current_tgt then
        local cur_ud = (ctx.units.by_unit and ctx.units.by_unit[current_tgt]) or (AAF_SM and AAF_SM.get_udata and AAF_SM.get_udata(current_tgt))
        if cur_ud then
          local cur_in_arc = M.is_target_in_fire_arc(unit, current_tgt)
          cur_score = M.compute_threat_score(udata.x, udata.z, current_tgt, cur_ud, cur_in_arc)
        end
      end
      local current_bearing = M.get_bearing_deg(unit)
      local target_bearing = M.bearing_to_point(udata.x, udata.z, ex, ez)
      if not (current_bearing and target_bearing) then break end
      local diff = math.abs(M.angle_diff_180(current_bearing, target_bearing))
      local is_switch = enemy ~= current_tgt
      local out_of_arc = diff > (C.FIRE_ARC_TOLERANCE_DEG or 90)
      local enemy_ud = (ctx.units.by_unit and ctx.units.by_unit[enemy]) or (AAF_SM and AAF_SM.get_udata and AAF_SM.get_udata(enemy))
      local cur_ud = (ctx.units.by_unit and ctx.units.by_unit[current_tgt]) or (AAF_SM and AAF_SM.get_udata and AAF_SM.get_udata(current_tgt))
      local enemy_ranged = M.is_ranged_unit(enemy, enemy_ud)
      local cur_ranged = M.is_ranged_unit(current_tgt, cur_ud)
      if not (enemy_ranged and M.is_target_in_range(unit, enemy, udata)) then
        if st._ranged_hold then st._ranged_hold[ukey] = nil end
      end
      -- 粘性保持：仅当当前目标也是远程且可射击未溃逃时，避免同优先级频繁切换；
      -- 当前为非远程时放行，让 ranged_upgrade / is_upgrade 把目标升级到更高优先级
      if has_tgt and cur_ranged and cur_score >= 0 and cur_vision_ok and cur_in_range and not cur_routing then
        st._target_since_ms[ukey] = now_ms
        break
      end
      local enemy_valid = M.is_target_shootable(unit, enemy, udata, shooter_ballistic)
      local blacklisted = M.is_target_blacklisted(st, M.unit_stable_key(unit), enemy)
      local can_strike = ((not C.REQUIRE_STATIC_STRIKE) or M.firing_solution(unit, enemy, udata, shooter_ballistic)) and (not blacklisted)
      local do_acquire = (not has_tgt) and enemy_valid and can_strike
      local ranged_upgrade = has_tgt and is_switch and enemy_ranged and (not cur_ranged) and enemy_valid and can_strike
      local is_upgrade = has_tgt and is_switch and (enemy_score >= cur_score + 500) and enemy_valid and can_strike
      local need_reface = has_tgt and (not is_switch) and out_of_arc and can_strike
      -- 仅低价值溃逃（tier 0）算作目标失效；高价值溃逃保留，由 is_upgrade 判断是否切换
      local cur_target_dead = has_tgt and ((not cur_in_range) or (not cur_vision_ok) or target_stale or no_fire_stale or cur_low_rout)
      local forced_switch = cur_target_dead and is_switch and enemy_valid and can_strike
      if not (do_acquire or ranged_upgrade or is_upgrade or need_reface or forced_switch) then
        if cur_low_rout then
          M._clear_attack(api, st, ukey, unit, now_ms, C, scene)
          M.dbg(api, st, 1, "ROUT_CLEAR unit="..tostring(ukey).." no_switch_target")
        end
        st._target_since_ms[ukey] = now_ms
        break
      end
      if C.SKIP_FAR_TARGETS then
        if can_strike then
          local cr = M.get_missile_range(unit, udata)
          local frac = C.COMMAND_RANGE_FRACTION or 0.4
          local cap = C.COMMAND_MAX_RANGE_M or 100
          local is_far = (cr and cr > 0 and edist and edist > cr * frac) or (edist and edist > cap) or false
          if is_far then
            -- 跳过远目标：不登记目标也不设冷却，下秒重新评估
            M.dbg(api, st, 1, string.format("SKIP_FAR unit=%s dist=%.1f range=%.1f", tostring(ukey), edist or 0, cr or 0))
            break
          end
        end
      end
      local cooldown_until = st._cooldowns[ukey] or 0
      if now_ms < cooldown_until and not (ranged_upgrade or is_upgrade or forced_switch) then break end
      if M.attack_target_remaining_cd(st, ukey, enemy, now_ms, C) > 0 then break end
      local session = api.get_session_for_unit(unit) or api.request_session(scene, unit, { role = "auto_attack" })
      if not (session and api.is_session_owner(scene, session)) then break end
      local rpos = M.safe_call(unit, "ordered_position")
      local rb   = M.safe_call(unit, "ordered_bearing")
      local rw   = M.safe_call(unit, "ordered_width")
      if M.issue_attack_once(api, scene, session, unit, enemy, udata, now_ms, rpos, rb, rw, st) then
        st._cooldowns[ukey] = now_ms + C.UNIT_COOLDOWN_MS
        st._last_bearing[ukey] = target_bearing
        st._last_order_ms[ukey] = now_ms
        if ranged_upgrade or (do_acquire and enemy_ranged) then
          st._ranged_hold = st._ranged_hold or {}
          st._ranged_hold[ukey] = M.unit_stable_key(enemy)
        end
        processed = processed + 1
        M.dbg(api, st, 1, string.format("attack_cmd unit=%s diff=%.1f dist=%.1f switch=%s upgrade=%s",
          tostring(ukey), diff, edist or 0, tostring(is_switch), tostring(is_upgrade)))
      end
    until true
  end
end
-- 会话 tick（本场景未使用）
function M.on_session_tick(scene, session, ctx, api) end
-- 战斗开始时重置跨战斗残留状态
function M.reset_mod_state()
  M._mod_enabled = nil
  M._player_cmd_real_ms = {}
end
scene.on_tick = M.on_tick
scene.on_session_tick = M.on_session_tick
scene.reset_mod_state = M.reset_mod_state
return scene

