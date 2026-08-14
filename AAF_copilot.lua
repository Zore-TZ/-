local SCENE_CONFIG = {
  { module = "script/battle/mod/AAF_scene_auto_face_enemy", enabled = true, priority = 1000 },
}

local AAF_LOG_FILE   = "wh3_aaf_debug.txt"
local AAF_ENABLE_LOG = true
local AAF_DEBUG      = true

-- 日志缓冲写入：减少 50ms tick 下的文件 I/O
local AAF_LOG_FLUSH_LINES = 64
local _log_buf, _log_buf_n = {}, 0

local function aaf_flush_log()
  if _log_buf_n == 0 then return end
  local ok, f = pcall(io.open, AAF_LOG_FILE, "a")
  if ok and f then
    for i = 1, _log_buf_n do f:write(_log_buf[i] .. "\n") end
    f:close()
  end
  _log_buf_n = 0
  for i = 1, #_log_buf do _log_buf[i] = nil end
end

local function aaf_write_file(line, mode)
  if not AAF_ENABLE_LOG then return end
  if mode == "a" then
    _log_buf_n = _log_buf_n + 1
    _log_buf[_log_buf_n] = line
    if _log_buf_n >= AAF_LOG_FLUSH_LINES then aaf_flush_log() end
  else
    aaf_flush_log()
    local ok, f = pcall(io.open, AAF_LOG_FILE, mode)
    if ok and f then f:write(line .. "\n"); f:close() end
  end
end

function aaf_log(msg)
  if not AAF_ENABLE_LOG then return end
  local line = string.format("[AAF][%s] %s", os.date("%H:%M:%S"), tostring(msg))
  if AAF_DEBUG and bm and bm.out then pcall(function() bm:out(line) end) end
  aaf_write_file(line, "a")
end

function aaf_debug(msg)
  if AAF_DEBUG then aaf_log(msg) end
end

if AAF_ENABLE_LOG then aaf_write_file("==== NEW AAF LOG ====", "a") end

if not bm and battle_manager and empire_battle then
  bm = battle_manager:new(empire_battle:new())
end

aaf_log("AAF_copilot.lua LOADED; bm="..tostring(bm ~= nil).." rcb="..tostring(bm and bm.repeat_callback ~= nil).." phase_cb="..tostring(bm and bm.register_phase_change_callback ~= nil))

AAF_SM = nil
do
  local ok, mod = pcall(require, "script/battle/mod/AAF_state_machine")
  if ok and mod then AAF_SM = mod; aaf_log("AAF_state_machine loaded")
  else aaf_log("require AAF_state_machine failed: "..tostring(mod)) end
end

local AAF_UTIL = nil
do
  local ok, mod = pcall(require, "script/battle/mod/AAF_utils")
  if ok and mod then AAF_UTIL = mod; aaf_log("AAF_utils loaded")
  else aaf_log("require AAF_utils failed: "..tostring(mod)) end
end

local dist, vec2
if AAF_UTIL then
  dist = AAF_UTIL.dist
  vec2 = AAF_UTIL.vec2
else
  function dist(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx*dx + dz*dz)
  end
  local v_ctor = _G.v
  function vec2(x, z)
    if not v_ctor then return nil end
    local ok, a = pcall(v_ctor, x, z)
    if ok and a then return a end
    local ok2, b = pcall(v_ctor, x, 0, z)
    if ok2 and b then return b end
    return nil
  end
end

local safe_unit_pos   = AAF_SM and AAF_SM.safe_unit_pos   or function() return nil, nil end
local AAF_unit_key    = AAF_SM and AAF_SM.unit_key        or tostring
local unit_is_routing = AAF_SM and AAF_SM.unit_is_routing or function() return false end

local function safe_call(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, ret = pcall(fn, obj, ...)
  if not ok then return nil end
  return ret
end

local AAF_COPILOT = {
  cfg = {
    tick_ms            = 50,    -- 主循环 50ms(20Hz)，高频压制 attack_unit 走位
    no_move_timeout_ms = 0,     -- 关闭：原地不动射击是设计意图，不应超时释放
    no_move_eps        = 0.5,
    stuck_cooldown_ms  = 30000,
    stuck_reasons      = { NO_MOVE_TIMEOUT = true, STUCK = true },
    return_foreign_session_on_same_prio = true,
  },
  initialised         = false,
  active_callback_id  = nil,
  tick_idx            = 0,
  scenes              = {},
  scene_state         = {},
  sessions_by_unit    = {},
  stuck_by_unit       = {},
  uc_by_unit          = {},   -- 每单位复用专属 unit_controller，避免 group 泄漏导致 add_units 报错
  _end_seq            = 0,
}

local function copilot_now_ms()
  if bm and bm.time then
    local ok, t = pcall(function() return bm:time() end)
    if ok and type(t) == "number" and t >= 0 then return math.floor(t * 1000) end
  end
  return (AAF_COPILOT.tick_idx or 0) * (AAF_COPILOT.cfg.tick_ms or 50)
end

local function sort_scenes()
  table.sort(AAF_COPILOT.scenes, function(a, b) return (a.priority or 0) > (b.priority or 0) end)
end

function AAF_COPILOT.register_scene(scene)
  if type(scene) ~= "table" or type(scene.id) ~= "string" or type(scene.on_tick) ~= "function" then
    aaf_log("register_scene: invalid scene"); return
  end
  scene.priority         = scene.priority or 50
  scene.session_priority = scene.session_priority or scene.priority
  if scene.enabled == nil then scene.enabled = true end
  AAF_COPILOT.scenes[#AAF_COPILOT.scenes+1] = scene
  AAF_COPILOT.scene_state[scene.id] = AAF_COPILOT.scene_state[scene.id] or {}
  aaf_log(string.format("Scene registered: id=%s prio=%d", scene.id, scene.priority))
end

local function maybe_mark_unit_stuck(unit, reason_str)
  if not unit then return end
  local cfg = AAF_COPILOT.cfg
  local cooldown = cfg.stuck_cooldown_ms or 0
  if cooldown <= 0 then return end
  if not (cfg.stuck_reasons and cfg.stuck_reasons[reason_str]) then return end

  local now_ms = copilot_now_ms()
  local info = AAF_COPILOT.stuck_by_unit[unit] or {}
  info.blocked_until_ms = now_ms + cooldown
  info.last_reason, info.last_release_ms = reason_str, now_ms
  AAF_COPILOT.stuck_by_unit[unit] = info
  aaf_log(string.format("stuck_mark: unit=%s reason=%s cooldown=%dms", AAF_unit_key(unit), reason_str, cooldown))
end

local function remove_session_record(session)
  if not session then return end
  local unit = session.unit
  if unit then AAF_COPILOT.sessions_by_unit[unit] = nil; return end
  for u, s in pairs(AAF_COPILOT.sessions_by_unit) do
    if s == session then AAF_COPILOT.sessions_by_unit[u] = nil; return end
  end
end

local function safe_release_controller(session)
  if not session or session._released then return end
  session._released = true
  local uc = session.controller
  if uc then
    pcall(function() if uc.release_control then uc:release_control() end end)
    pcall(function() if uc.clear_all then uc:clear_all() end end)
  end
  session.controller = nil
end

local function end_session(session, reason)
  if not session then return end
  local reason_str = tostring(reason or "END")
  if session.ended then
    safe_release_controller(session)
    remove_session_record(session)
    return
  end
  AAF_COPILOT._end_seq = (AAF_COPILOT._end_seq or 0) + 1
  session.ended, session.end_reason = true, reason_str
  session.end_tick, session.end_seq = AAF_COPILOT.tick_idx, AAF_COPILOT._end_seq
  safe_release_controller(session)
  local unit = session.unit
  if unit and AAF_SM and AAF_SM.set_controller then
    pcall(function() AAF_SM.set_controller(unit, "ai") end)
  end
  remove_session_record(session)
  aaf_log(string.format("session_end: unit=%s scene=%s reason=%s",
    tostring(unit and AAF_unit_key(unit) or session.unit_key_str or "nil"),
    tostring(session.scene_id), reason_str))
  maybe_mark_unit_stuck(unit, reason_str)
end

local function release_session(session, reason)
  return end_session(session, reason or "SCENE_RELEASE")
end

-- 每单位复用同一个 controller：单位一旦进入该 controller 的 group，
-- 后续 session 只会对同一 controller 重加（pcall 吞掉无害的 "already in this controller"），
-- 彻底避免反复新建 controller 触发的 "already in another group" 错误（单位残留在旧 group 中）。
local function get_cached_controller(army, unit)
  local cached = AAF_COPILOT.uc_by_unit[unit]
  if cached and cached.uc and cached.army == army then
    return cached.uc
  end
  local ok_uc, uc = pcall(function() return army:create_unit_controller() end)
  if not ok_uc or not uc then
    aaf_log("create_session: failed for unit="..AAF_unit_key(unit))
    return nil
  end
  AAF_COPILOT.uc_by_unit[unit] = { uc = uc, army = army }
  return uc
end

local function create_session(scene, unit, army, args)
  args = args or {}
  local uc = get_cached_controller(army, unit)
  if not uc then return nil end
  -- 复用专属 controller：单位已在自身 group 内，add_units 为同 controller 重加，
  -- 即便报 "already in this controller" 也被 pcall 吞掉且不影响 take_control。
  pcall(function() uc:add_units(unit) end)
  uc:take_control()
  if AAF_SM and AAF_SM.set_controller then AAF_SM.set_controller(unit, "script") end

  local s = {
    unit = unit, army = army, controller = uc,
    scene = scene, scene_id = scene.id,
    role = args.role or scene.id,
    priority = args.priority or scene.session_priority or scene.priority or 50,
    created_tick = AAF_COPILOT.tick_idx,
    data = args.data or {},
    ended = false, _released = false,
    unit_key_str = AAF_unit_key(unit),
  }
  AAF_COPILOT.sessions_by_unit[unit] = s
  aaf_log(string.format("session_start: unit=%s scene=%s prio=%d", AAF_unit_key(unit), tostring(s.scene_id), tonumber(s.priority or -1)))
  return s
end

local function request_session(scene, unit, args, ctx)
  args = args or {}
  local existing = AAF_COPILOT.sessions_by_unit[unit]
  local new_prio = args.priority or scene.session_priority or scene.priority or 50
  local cfg = AAF_COPILOT.cfg
  local now_ms = (ctx and ctx.time_ms) or copilot_now_ms()

  local stuck = AAF_COPILOT.stuck_by_unit[unit]
  if stuck and stuck.blocked_until_ms then
    if now_ms < stuck.blocked_until_ms then return nil, "stuck_cooldown" end
    AAF_COPILOT.stuck_by_unit[unit] = nil
  end

  if existing then
    if existing.priority > new_prio then return nil, "keep_higher" end
    if existing.priority == new_prio then
      if existing.scene_id ~= scene.id then
        if cfg.return_foreign_session_on_same_prio ~= false then
          return existing, "same_prio_other_scene"
        end
        return nil, "same_prio_other_scene"
      end
      return existing, "reuse"
    end
    release_session(existing, string.format("PRIO_TAKEOVER old=%s new=%s", tostring(existing.scene_id), tostring(scene.id)))
  end

  local army = args.army
  if not army and ctx and ctx.units and ctx.units.by_unit then
    local udata = ctx.units.by_unit[unit]
    if udata then army = udata.army; args.udata = udata end
  end
  if not army then
    aaf_log("request_session: no army for unit="..AAF_unit_key(unit))
    return nil, "no_army"
  end

  args.priority = new_prio
  local s = create_session(scene, unit, army, args)
  if not s then return nil, "create_failed" end
  return s, "new"
end

local function build_ctx()
  local ctx = {
    tick = AAF_COPILOT.tick_idx,
    cfg = AAF_COPILOT.cfg, bm = bm, sm = AAF_SM, util = AAF_UTIL,
    time_ms = copilot_now_ms(),
    units = {
      all = AAF_SM and AAF_SM.unit_list or {},
      by_side = { player = {}, ally = {}, ai = {} },
      by_unit = AAF_SM and AAF_SM.units_by_unit or {},
    },
    sessions = AAF_COPILOT.sessions_by_unit,
    scene_state = AAF_COPILOT.scene_state,
  }
  for _, udata in ipairs(ctx.units.all) do
    if not udata.dead then
      local list = ctx.units.by_side[udata.side or "ai"]
      if list then list[#list+1] = udata end
    end
  end
  ctx.ai     = { units = ctx.units.by_side.ai }
  ctx.player = { units = ctx.units.by_side.player }
  ctx.ally   = { units = ctx.units.by_side.ally }
  return ctx
end

function AAF_COPILOT.make_api(ctx)
  local api = {}
  function api.request_session(scene, unit, args) return request_session(scene, unit, args, ctx) end
  function api.release_session(session, reason) return release_session(session, reason or "SCENE_RELEASE") end
  function api.get_session_for_unit(unit) return AAF_COPILOT.sessions_by_unit[unit] end
  function api.is_session_owner(scene, session) return session and scene and session.scene_id == scene.id end
  function api.unit_pos(unit) return safe_unit_pos(unit) end
  function api.scene_state(scene)
    local st = AAF_COPILOT.scene_state[scene.id or "?"]
    if not st then st = {}; AAF_COPILOT.scene_state[scene.id or "?"] = st end
    return st
  end
  function api.log(scene, msg) aaf_log("["..tostring(scene and scene.id or "?").."] "..tostring(msg)) end
  function api.debug(scene, msg) if AAF_DEBUG then aaf_debug("["..tostring(scene and scene.id or "?").."] "..tostring(msg)) end end
  api.dist, api.vec2 = dist, vec2
  return api
end

local function update_session_anchor_and_timeout(session, cfg)
  local timeout_ms = cfg.no_move_timeout_ms or 0
  if timeout_ms <= 0 then return false end

  local unit = session.unit
  local x, z = safe_unit_pos(unit)
  if not x then release_session(session, "NO_POS"); return true end

  local now_tick = AAF_COPILOT.tick_idx
  local eps = cfg.no_move_eps or 0.5

  if not session.anchor_x then
    session.anchor_x, session.anchor_z, session.anchor_tick = x, z, now_tick
    return false
  end

  if dist(x, z, session.anchor_x, session.anchor_z) > eps then
    session.anchor_x, session.anchor_z, session.anchor_tick = x, z, now_tick
    return false
  end

  local elapsed_ms = (now_tick - (session.anchor_tick or now_tick)) * (cfg.tick_ms or 3000)
  if elapsed_ms >= timeout_ms then
    release_session(session, "NO_MOVE_TIMEOUT")
    return true
  end
  return false
end

local function drive_sessions(ctx, api)
  local list = {}
  for unit, s in pairs(AAF_COPILOT.sessions_by_unit) do list[#list+1] = { unit = unit, session = s } end

  for _, pair in ipairs(list) do
    local unit, session = pair.unit, pair.session
    if AAF_COPILOT.sessions_by_unit[unit] then
      if (not unit) or unit_is_routing(unit) then
        release_session(session, unit and "ROUTING" or "NO_UNIT")
      else
        local scene = session.scene
        if scene and scene.on_session_tick then
          local ok, err = pcall(scene.on_session_tick, scene, session, ctx, api)
          if not ok then aaf_log("scene "..tostring(scene.id).." on_session_tick error: "..tostring(err)) end
        end
        if AAF_COPILOT.sessions_by_unit[unit] then
          update_session_anchor_and_timeout(session, AAF_COPILOT.cfg)
        end
      end
    end
  end
end

-- 注意：必须定义在 copilot_tick_impl 之前，否则 tick 内引用会退化为全局 nil
local function context_guard_ok()
  if not bm then return false end
  if safe_call(bm, "is_battle_running") == false then
    return false
  end
  return true
end

local function copilot_tick_impl()
  if not AAF_COPILOT.initialised then return end
  AAF_COPILOT.tick_idx = AAF_COPILOT.tick_idx + 1

  -- 轻量防御：战斗未真正开始时不执行单位扫描，避免空跑
  if not context_guard_ok() then return end

  if AAF_SM and AAF_SM.update then AAF_SM.update(AAF_COPILOT.tick_idx) end

  local ctx = build_ctx()
  local api = AAF_COPILOT.make_api(ctx)

  for _, scene in ipairs(AAF_COPILOT.scenes) do
    if scene.enabled ~= false and scene.on_tick then
      local ok, err = pcall(scene.on_tick, scene, ctx, api)
      if not ok then aaf_log("scene "..tostring(scene.id).." on_tick error: "..tostring(err)) end
    end
  end

  drive_sessions(ctx, api)

  if AAF_COPILOT.tick_idx % 20 == 0 then aaf_flush_log() end
end

local function aaf_copilot_tick()
  local ok, err = pcall(copilot_tick_impl)
  if not ok then aaf_log("ERROR in copilot_tick_impl: "..tostring(err)) end
end

local function load_scenes_from_config()
  for _, conf in ipairs(SCENE_CONFIG) do
    if conf.module and conf.enabled ~= false then
      local ok, scene = pcall(require, conf.module)
      if ok and scene then
        if conf.priority then scene.priority = conf.priority end
        if conf.session_priority then scene.session_priority = conf.session_priority end
        if conf.enabled ~= nil then scene.enabled = conf.enabled end
        AAF_COPILOT.register_scene(scene)
        if scene.on_register then
          local ok2, err2 = pcall(scene.on_register, scene, AAF_COPILOT)
          if not ok2 then aaf_log("scene "..tostring(scene.id).." on_register error: "..tostring(err2)) end
        end
      else
        aaf_log("require scene failed: "..tostring(conf.module).." err="..tostring(scene))
      end
    end
  end
  sort_scenes()
end

local function copilot_teardown()
  if not AAF_COPILOT.initialised then return end
  aaf_log("copilot_teardown()")
  -- bm:repeat_callback 不返回 id，WH3 用回调名移除；两种 API 都试一遍
  if bm then
    if bm.remove_process then
      pcall(function() bm:remove_process("aaf_copilot_tick") end)
    end
    if bm.remove_callback then
      pcall(function() bm:remove_callback("aaf_copilot_tick") end)
    end
  end
  AAF_COPILOT.active_callback_id = nil
  AAF_COPILOT.initialised = false
  AAF_COPILOT.sessions_by_unit = {}
  AAF_COPILOT.uc_by_unit = {}
  AAF_COPILOT.scene_state = {}
  AAF_COPILOT.tick_idx = 0
  aaf_log("copilot state reset")
  aaf_flush_log()
end

local function copilot_init()
  if AAF_COPILOT.initialised then return end
  aaf_log("copilot_init() [phase=Deployed]")
  -- 不在此处做 context_guard，避免早期回调导致初始化失败、callback 永远不注册
  if not AAF_SM or not AAF_SM.init_from_bm then
    aaf_log("AAF_SM not loaded, copilot disabled")
    return
  end
  AAF_SM.init_from_bm(bm)
  load_scenes_from_config()
  -- 每场战斗开始时重置各 scene 的跨战斗残留状态（如 mod 开关），确保默认开启
  for _, scene in ipairs(AAF_COPILOT.scenes or {}) do
    if type(scene.reset_mod_state) == "function" then
      pcall(function() scene:reset_mod_state() end)
    end
  end
  if bm and bm.repeat_callback then
    -- 防止上一场战斗的同名回调残留导致每帧执行两次
    if bm.remove_process then pcall(function() bm:remove_process("aaf_copilot_tick") end) end
    AAF_COPILOT.active_callback_id = bm:repeat_callback(
      function() aaf_copilot_tick() end,
      AAF_COPILOT.cfg.tick_ms,
      "aaf_copilot_tick"
    )
    AAF_COPILOT.initialised = true
    aaf_log("copilot started (id="..tostring(AAF_COPILOT.active_callback_id)..")")
  else
    aaf_log("bm.repeat_callback missing; copilot not started")
  end
end

-- 自举：无论脚本加载时序如何，战斗就绪即启动
-- 1) 多相位兜底：Deployed/Deployment/Battle 任一触发即 init
-- 2) 若加载时战斗已在运行，立即 init
-- 3) 若上述都错过，靠下面注册的 bootstrap 回调每 1s 自省
local function try_init_now(reason)
  if AAF_COPILOT.initialised then return end
  if not (bm and bm.repeat_callback) then return end
  aaf_log("try_init_now("..tostring(reason)..") bm_ok="..tostring(bm ~= nil))
  copilot_init()
end

if bm and bm.register_phase_change_callback then
  for _, phase in ipairs({ "Deployed", "Deployment", "Battle", "BattleStarted" }) do
    pcall(function()
      bm:register_phase_change_callback(phase, function()
        aaf_log("Phase="..phase.." -> copilot_init")
        try_init_now("phase:"..phase)
      end)
    end)
  end
  for _, phase in ipairs({ "BattleEnded", "Complete", "BattleEnd" }) do
    pcall(function()
      bm:register_phase_change_callback(phase, function()
        aaf_log("Phase="..phase.." -> copilot_teardown")
        copilot_teardown()
      end)
    end)
  end
else
  aaf_log("bm.register_phase_change_callback missing; copilot not hooked")
end

-- bootstrap 回调：脚本加载时若 bm 已可用，注册一个慢速自省回调
-- 即使所有相位回调都错过，也能在战斗开始后 1s 内自行启动
if bm and bm.repeat_callback then
  bm:repeat_callback(function()
    if not AAF_COPILOT.initialised then
      -- 战斗就绪判定：bm 存在且（is_battle_running 为真或不存在该方法）
      local running = true
      if bm.is_battle_running then
        running = (bm:is_battle_running() ~= false)
      end
      if running then try_init_now("bootstrap") end
    end
  end, 1000, "aaf_bootstrap")
  aaf_log("bootstrap callback registered")
else
  aaf_log("bm.repeat_callback missing; cannot self-start")
end

-- 加载时若战斗已在运行（脚本加载较晚的情况），直接尝试启动
if bm and bm.is_battle_running and bm:is_battle_running() then
  try_init_now("loaded_already_running")
end

return AAF_COPILOT
