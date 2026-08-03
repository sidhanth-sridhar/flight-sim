--!strict
--[[
	MathUtil
	--------
	Math helpers Roblox does not provide, used throughout the flight model,
	control smoothing and camera code.

	Deliberately excludes anything already built in (math.clamp, math.sign,
	math.rad) - wrapping those would only add a call layer to hot loops.

	PERFORMANCE: every function here is called up to several times per frame
	per aerodynamic surface. They allocate nothing and localise the math
	library functions they use.
]]

local MathUtil = {}

local abs = math.abs
local exp = math.exp
local max = math.max
local pi = math.pi

-- =========================================================================
-- INTERPOLATION
-- =========================================================================

-- Standard linear interpolation. t is NOT clamped, so this doubles as
-- extrapolation when a caller deliberately passes t outside [0, 1].
function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- The inverse: where does `v` sit between a and b, as a 0-1 fraction?
-- Returns 0 when a == b rather than dividing by zero.
function MathUtil.inverseLerp(a: number, b: number, v: number): number
	if a == b then
		return 0
	end
	return (v - a) / (b - a)
end

-- Map a value from one range to another. Used constantly by instruments
-- (e.g. 0-160 knots -> 0-270 degrees of needle rotation).
function MathUtil.remap(v: number, inMin: number, inMax: number, outMin: number, outMax: number, clampResult: boolean?): number
	local t = MathUtil.inverseLerp(inMin, inMax, v)
	if clampResult then
		t = math.clamp(t, 0, 1)
	end
	return outMin + (outMax - outMin) * t
end

-- =========================================================================
-- SMOOTHING
-- =========================================================================
-- Realistic controls are the whole point of this project, and the difference
-- between "instant" and "smooth" input is these two functions.

--[[
	Frame-rate independent exponential smoothing.

	The naive version everyone writes first is:
		current = lerp(current, target, 0.1)
	...which is WRONG, because it converges twice as fast at 120 fps as at
	60 fps - the aircraft would literally handle differently on better
	hardware. The exponential form below converges at the same real-time rate
	regardless of frame rate.

	`lambda` is the decay rate: higher = snappier. lambda = 10 closes roughly
	63% of the remaining gap every 0.1 s.
]]
function MathUtil.damp(current: number, target: number, lambda: number, dt: number): number
	return target + (current - target) * exp(-lambda * dt)
end

--[[
	Critically damped spring (the same algorithm as Unity's SmoothDamp).

	Unlike damp(), this carries velocity, so it eases OUT of motion as well as
	into it and never overshoots. This is what makes a control surface feel
	like it has mass rather than like a filtered number.

	The caller owns the velocity variable:
		local pos, vel = 0, 0
		pos, vel = MathUtil.smoothDamp(pos, target, vel, 0.15, dt)

	The expTerm below is a cheap rational approximation of exp(-x), accurate
	to ~0.1% over the range we care about and considerably faster.
]]
function MathUtil.smoothDamp(
	current: number,
	target: number,
	velocity: number,
	smoothTime: number,
	dt: number,
	maxSpeed: number?
): (number, number)
	smoothTime = max(0.0001, smoothTime)

	local omega = 2 / smoothTime
	local x = omega * dt
	local expTerm = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

	local originalTarget = target
	local change = current - target

	-- Optional speed cap, e.g. a servo that physically cannot slew faster.
	if maxSpeed then
		local maxChange = maxSpeed * smoothTime
		change = math.clamp(change, -maxChange, maxChange)
		target = current - change
	end

	local temp = (velocity + omega * change) * dt
	local newVelocity = (velocity - omega * temp) * expTerm
	local output = target + (change + temp) * expTerm

	-- Guard against overshooting the target on large timesteps.
	if (originalTarget - current > 0) == (output > originalTarget) then
		output = originalTarget
		newVelocity = (output - originalTarget) / dt
	end

	return output, newVelocity
end

-- Move `current` toward `target` by at most `maxDelta`. Linear, no easing.
-- Used where a rate limit is physically correct - flaps extending at a fixed
-- degrees/second, gear travelling at a fixed rate.
function MathUtil.approach(current: number, target: number, maxDelta: number): number
	local delta = target - current
	if abs(delta) <= maxDelta then
		return target
	end
	return current + (delta > 0 and maxDelta or -maxDelta)
end

-- =========================================================================
-- INPUT SHAPING
-- =========================================================================

-- Removes drift near centre, then rescales the remainder so the full output
-- range is still reachable (without the rescale, a 0.1 deadzone would cap
-- output at 0.9 and the aircraft could never reach full deflection).
function MathUtil.deadzone(v: number, threshold: number): number
	local m = abs(v)
	if m < threshold then
		return 0
	end
	local scaled = (m - threshold) / (1 - threshold)
	return v > 0 and scaled or -scaled
end

--[[
	Exponential control curve - the single most important function for making
	mouse and stick input feel good.

	expo = 0 gives a linear response.
	expo = 1 gives a pure cubic: fine, precise control near centre for trimming
	and formation work, while full deflection is still available at the edges.

	Real aircraft yokes feel like this because of mechanical linkage geometry.
]]
function MathUtil.expo(v: number, expoAmount: number): number
	if expoAmount <= 0 then
		return v
	end
	return v * (1 - expoAmount) + (v * v * v) * expoAmount
end

-- =========================================================================
-- ANGLES
-- =========================================================================

-- Wrap an angle into (-pi, pi]. Essential for heading maths: without it,
-- turning from 350 deg to 10 deg looks like a 340 deg turn the wrong way.
function MathUtil.wrapAngle(radians: number): number
	radians = (radians + pi) % (2 * pi)
	if radians < 0 then
		radians += 2 * pi
	end
	return radians - pi
end

-- Shortest signed angular distance from `from` to `to`, in radians.
function MathUtil.angleDelta(from: number, to: number): number
	return MathUtil.wrapAngle(to - from)
end

-- Interpolate between angles the short way around the circle.
function MathUtil.lerpAngle(from: number, to: number, t: number): number
	return MathUtil.wrapAngle(from + MathUtil.angleDelta(from, to) * t)
end

-- Normalise a compass heading into [0, 360). Instruments display this.
function MathUtil.normalizeHeading(degrees: number): number
	degrees %= 360
	if degrees < 0 then
		degrees += 360
	end
	return degrees
end

-- =========================================================================
-- MISC
-- =========================================================================

-- Round to the nearest multiple of `step`. Instruments use this to snap
-- readouts to realistic precision (an altimeter reads in 20 ft increments,
-- not 3847.2183 ft).
function MathUtil.roundTo(v: number, step: number): number
	if step <= 0 then
		return v
	end
	return math.round(v / step) * step
end

-- Guards against NaN and infinity leaking into the physics state. A single
-- NaN in a force vector permanently corrupts a Roblox assembly - the part
-- disappears and cannot be recovered without a respawn - so the flight model
-- filters every value it writes to a constraint through this.
function MathUtil.sanitize(v: number, fallback: number?): number
	if v ~= v or v == math.huge or v == -math.huge then
		return fallback or 0
	end
	return v
end

-- Vector3 equivalent of sanitize(), applied to every force and torque before
-- it reaches a constraint.
function MathUtil.sanitizeVector(v: Vector3): Vector3
	local x, y, z = v.X, v.Y, v.Z
	if x ~= x or y ~= y or z ~= z then
		return Vector3.zero
	end
	if abs(x) == math.huge or abs(y) == math.huge or abs(z) == math.huge then
		return Vector3.zero
	end
	return v
end

-- Clamp a vector's length without changing its direction. Used as a final
-- safety net on aerodynamic forces during extreme flight states.
function MathUtil.clampMagnitude(v: Vector3, maxLength: number): Vector3
	local m = v.Magnitude
	if m > maxLength and m > 0 then
		return v * (maxLength / m)
	end
	return v
end

return MathUtil
