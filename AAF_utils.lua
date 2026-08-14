local M = {}

function M.dist2(ax, az, bx, bz)
  local dx, dz = ax - bx, az - bz
  return dx*dx + dz*dz
end

function M.dist(ax, az, bx, bz)
  return math.sqrt(M.dist2(ax, az, bx, bz))
end

function M.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

M.PI = math.pi

-- 构造引擎 vec2 对象(兼容 v(x,z) / v(x,0,z) 两种签名)
function M.vec2(x, z)
  local v_ctor = _G.v
  if v_ctor then
    local ok, a = pcall(v_ctor, x, z)
    if ok and a then return a end
    local ok2, b = pcall(v_ctor, x, 0, z)
    if ok2 and b then return b end
  end
  return nil
end

-- 单位能否到达指定坐标(无接口时保守返回 true)
function M.can_reach(unit, x, z)
  if not unit or type(x) ~= "number" or type(z) ~= "number" then return false end
  if type(unit.can_reach_position) ~= "function" then return true end
  local bv = M.vec2(x, z)
  if not bv then return true end
  local ok, res = pcall(unit.can_reach_position, unit, bv)
  if not ok then return true end
  return res and true or false
end

-- 在 (x,z) 附近环形搜索可达点
function M.find_reachable_near(unit, x, z, opts)
  opts = opts or {}
  if M.can_reach(unit, x, z) then return x, z, false end

  local base  = opts.base  or 4
  local step  = opts.step  or 4
  local rings = opts.rings or 3
  local angles = opts.angles_deg or {0,45,90,135,180,225,270,315,22.5,67.5,112.5,157.5,202.5,247.5,292.5,337.5}

  for i = 1, rings do
    local r = base + (i - 1) * step
    for _, deg in ipairs(angles) do
      local ang = (deg * M.PI) / 180.0
      local tx, tz = x + math.cos(ang) * r, z + math.sin(ang) * r
      if M.can_reach(unit, tx, tz) then return tx, tz, true end
    end
  end
  return x, z, false
end

return M
