--!strict
--[[
	DebugHud
	--------
	Raw numbers, on screen, while flying. No gauges, no dials, no needles.

	This is the diagnostic instrument for the whole project: the place a wrong
	coefficient or a bad sign becomes visible. Every value is printed as a
	number because a number can be compared against a published figure, and a
	needle cannot. Pretty instruments are a later phase and are deliberately
	not started here.

	WHERE THE NUMBERS COME FROM
	---------------------------
	FlightModel.computeForces writes state.telemetry every physics frame. This
	module only reads it. It applies no forces, owns no state the physics can
	see, and would change nothing about how the aircraft flies if it were
	deleted mid-flight.

	UNITS ARE CONVERTED HERE, AND ONLY HERE
	---------------------------------------
	The physics is pure SI and must stay that way - the handoff is explicit
	that the physics never sees knots. This module is the boundary: metres per
	second become knots, radians become degrees, and nothing converted here
	ever travels back the other way.

	IT MUST NOT EAT MOUSE INPUT
	---------------------------
	The cursor is the yoke, and it roams the entire screen because the screen
	edge is full control deflection. So every element here is inert: no
	buttons, nothing Active, nothing that could swallow a click or block the
	pointer. The panel sits down the left edge for the same reason - it keeps
	the middle of the screen, where the yoke's neutral is, visually clear.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Units = require(FlightSim.Shared.Units)

local FlightController = require(script.Parent.Parent.Parent:WaitForChild("Controllers"):WaitForChild("FlightController"))

local DebugHud = {}

-- =========================================================================
-- APPEARANCE
-- =========================================================================

local PANEL_WIDTH = 250
local PANEL_INSET = 12
local ROW_HEIGHT = 15
local FONT_SIZE = 13

--[[
	Monospace, and not as a style choice.

	A proportional font re-flows every row as the digits change, so a value
	oscillating between 9 and 10 makes the whole column twitch and the panel
	becomes genuinely hard to read in flight. Code is fixed-width, so columns
	stay put.
]]
local FONT = Enum.Font.Code

local COLOR_LABEL = Color3.fromRGB(150, 160, 170)
local COLOR_VALUE = Color3.fromRGB(235, 240, 245)
local COLOR_HEADER = Color3.fromRGB(120, 190, 255)
local COLOR_PEAK = Color3.fromRGB(255, 190, 110)

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local rows: { [string]: TextLabel } = {}
local connection: RBXScriptConnection? = nil
local initialised = false

--[[
	Whether the pilot wants the HUD at all, as opposed to whether there is
	anything to show on it.

	Two separate questions, and conflating them was the old design: the panel is
	visible only when this is true AND the pilot is flying. The constant seeds
	it and nothing else reads the constant afterwards - see setVisible().
]]
local hudWanted = Constants.DEBUG.SHOW_PHYSICS_OVERLAY == true

local redrawAccumulator = 0

--[[
	Peaks, sampled every frame and shown until the next redraw.

	The redraw runs at 30 Hz but the physics runs at frame rate, so a plain
	30 Hz readout silently drops most of what happens between samples. That
	matters here more than on an ordinary gauge: FlightModel clamps its force
	at 20 g precisely because spikes occur, and a spike that lasts one frame
	is exactly the event worth knowing about. So the numbers are sampled every
	frame even though they are only drawn thirty times a second.
]]
-- Kept in step with newPeaks() by a test, because this literal and that
-- constructor are two places to add a field and one place to forget.
local peaks = { loadFactor = 0, forceMagnitude = 0, alpha = 0 }

-- =========================================================================
-- FORMATTING
-- =========================================================================
-- Pure, and separated from every Roblox instance so runTests() can assert on
-- the exact strings without building a GUI or flying an aeroplane.

--[[
	Format one number, defensively.

	nil and NaN are both reported rather than hidden. A NaN on this panel is
	not a display bug to paper over - it is the single most valuable thing the
	HUD can tell you, because it means the physics has gone numerically bad and
	every value downstream of it is meaningless.
]]
function DebugHud.num(value: any, format: string): string
	if type(value) ~= "number" then
		return "--"
	end
	if value ~= value then
		return "NaN"
	end
	if value == math.huge or value == -math.huge then
		return if value > 0 then "+INF" else "-INF"
	end
	return string.format(format, value)
end

local function deg(radians: any): number?
	if type(radians) ~= "number" then
		return nil
	end
	return math.deg(radians)
end

--[[
	The core block, as ordered label/value pairs.

	Returned as data rather than written straight into TextLabels so the tests
	can read exactly what a pilot would see, which is the only way to catch a
	unit conversion that is silently the wrong way round.
]]
function DebugHud.formatCore(telemetry: any, peakState: any?): { { label: string, value: string, peak: string? } }
	local t = telemetry or {}
	local p = peakState

	local force = if typeof(t.force) == "Vector3" then t.force else Vector3.zero
	local torque = if typeof(t.torque) == "Vector3" then t.torque else Vector3.zero

	local verticalSpeed = t.verticalSpeed
	local vsFpm = if type(verticalSpeed) == "number" then Units.msToFeetPerMin(verticalSpeed) else nil

	return {
		-- Airspeed in knots, because that is the unit every published figure
		-- for this aircraft is quoted in. IAS is what the pilot flies; TAS is
		-- what the aerodynamics actually used.
		{ label = "IAS", value = DebugHud.num(if type(t.airspeedIndicated) == "number" then Units.msToKnots(t.airspeedIndicated) else nil, "%7.1f kt") },
		{ label = "TAS", value = DebugHud.num(if type(t.airspeedTrue) == "number" then Units.msToKnots(t.airspeedTrue) else nil, "%7.1f kt") },
		{ label = "ALT", value = DebugHud.num(t.altitude, "%7.1f m") },
		{ label = "VS", value = DebugHud.num(verticalSpeed, "%+7.2f m/s") .. " " .. DebugHud.num(vsFpm, "%+6.0f fpm") },

		--[[
			AoA, its peak since the last redraw, and whether it is a stall.

			The peak is here for the same reason it is on G: the stall break is
			a sub-second event and the redraw runs at 30 Hz.

			The stall marker is the only judgement on this panel. It earns its
			place because alpha alone cannot tell a pilot whether the number in
			front of them is fine or a departure, and the wing's stall angle is
			carried in the telemetry precisely so this line can say so.
		]]
		{
			label = "AoA",
			value = DebugHud.num(deg(t.alpha), "%+7.2f deg")
				.. (
					if DebugHud.stallState(t.alpha, t.stallAlpha) == "stall" then "  << STALL"
					elseif DebugHud.stallState(t.alpha, t.stallAlpha) == "approaching" then "  < buffet"
					else ""
				),
			peak = if p then DebugHud.num(deg(p.alpha), "pk %+.1f") else nil,
		},

		--[[
			ATTITUDE, and it is directly beneath AoA on purpose.

			These two are constantly confused, and the confusion is what made the
			AoA readout look broken: in a climbing pull the nose can be 20 degrees
			up while alpha is only 8, because the flight path curves to follow it.
			Alpha is measured against the AIRFLOW, attitude against the HORIZON.
			Showing them adjacent makes the difference legible instead of
			mysterious.
		]]
		{
			label = "ATT",
			value = DebugHud.num(deg(t.pitchAttitude), "%+7.2f deg")
				.. "  bank " .. DebugHud.num(deg(t.bankAngle), "%+.1f"),
		},

		{ label = "BETA", value = DebugHud.num(deg(t.beta), "%+7.2f deg") },
		{
			label = "G",
			value = DebugHud.num(t.loadFactor, "%+7.2f g"),
			peak = if p then DebugHud.num(p.loadFactor, "pk %+.2f") else nil,
		},

		{ label = "THRUST", value = DebugHud.num(t.thrust, "%7.0f N") },
		{ label = "RPM", value = DebugHud.num(t.rpm, "%7.0f") },
		{ label = "FUEL", value = DebugHud.num(t.fuelKg, "%7.1f kg") },
		{ label = "RHO", value = DebugHud.num(t.density, "%7.4f kg/m3") },
		{ label = "Q", value = DebugHud.num(t.dynamicPressure, "%7.0f Pa") },

		--[[
			Force and torque as raw components, not a magnitude and not an
			arrow drawn in the world. The signs are the point: in body axes -Z
			is forward and +Y is up, so a glance tells you whether the model
			is pushing the aeroplane the way you think it is.

			THIS IS THE AERODYNAMIC AND PROPULSIVE FORCE ONLY. It is what
			FlightModel computed, not what was finally written to the
			constraint - FlightController adds GroundHandling's contribution
			before writing. So on the ground these numbers legitimately differ
			from AeroForce.Force, and the difference IS the gear load. In the
			air, where the gear contributes nothing, the two agree.
		]]
		{
			label = "FORCE",
			value = string.format("%s %s %s N", DebugHud.num(force.X, "X%+8.0f"), DebugHud.num(force.Y, "Y%+8.0f"), DebugHud.num(force.Z, "Z%+8.0f")),
			peak = if p then DebugHud.num(p.forceMagnitude, "pk %.0f N") else nil,
		},
		{
			label = "TORQUE",
			value = string.format("%s %s %s Nm", DebugHud.num(torque.X, "X%+8.0f"), DebugHud.num(torque.Y, "Y%+8.0f"), DebugHud.num(torque.Z, "Z%+8.0f")),
		},
	}
end

--[[
	One row per aerodynamic surface.

	This is where the per-surface model earns its keep as a diagnostic: an
	asymmetric stall shows up as WingLeft and WingRight diverging, and a tail
	that has stopped contributing shows up as a Stabilizer CL that never moves.
	Neither is visible from any whole-aircraft number.
]]
function DebugHud.formatSurfaces(telemetry: any): { { name: string, value: string } }
	local out = {}
	local surfaces = telemetry and telemetry.surfaces
	if type(surfaces) ~= "table" then
		return out
	end

	for _, s in surfaces do
		table.insert(out, {
			name = tostring(s.name),
			value = string.format(
				"%s %s %s",
				DebugHud.num(deg(s.alpha), "%+6.1f"),
				DebugHud.num(s.cl, "%+7.3f"),
				DebugHud.num(s.cd, "%6.3f")
			),
		})
	end

	return out
end

-- =========================================================================
-- PEAKS
-- =========================================================================

function DebugHud.newPeaks(): any
	return { loadFactor = 0, forceMagnitude = 0, alpha = 0 }
end

-- Absolute value, so a hard negative g excursion registers as the peak it is.
function DebugHud.samplePeaks(peakState: any, telemetry: any)
	if not (peakState and telemetry) then
		return
	end

	local g = telemetry.loadFactor
	if type(g) == "number" and g == g and math.abs(g) > math.abs(peakState.loadFactor) then
		peakState.loadFactor = g
	end

	local force = telemetry.force
	if typeof(force) == "Vector3" then
		local magnitude = force.Magnitude
		if magnitude == magnitude and magnitude > peakState.forceMagnitude then
			peakState.forceMagnitude = magnitude
		end
	end

	--[[
		ALPHA GETS A PEAK TOO, and it should have had one from the start.

		The note at the top of this file argues that a 30 Hz readout drops most
		of what happens between samples, and applies that to g and to force. It
		is just as true of alpha and was not applied - which is what made the
		stall look like it never happened. Measured on a real stall entry: alpha
		sat between 8 and 14 degrees through the pull, touched 18.6 at the break,
		and was back under 3 within a second and a half. At 30 Hz the one number
		worth seeing is the one most likely to be missed.
	]]
	local a = telemetry.alpha
	if type(a) == "number" and a == a and math.abs(a) > math.abs(peakState.alpha) then
		peakState.alpha = a
	end
end

function DebugHud.resetPeaks(peakState: any)
	peakState.loadFactor = 0
	peakState.forceMagnitude = 0
	peakState.alpha = 0
end

--[[
	Is this angle of attack a stall?

	Pure and exported, because it is the one piece of judgement on this panel
	and the tests should be able to drive it directly. Returns "stall",
	"approaching", or nil.

	`approaching` starts 3 degrees below the stall angle, which is roughly where
	a real aircraft's stall warning horn is set - far enough ahead to be a
	warning rather than a commentary.

	Returns nil when the aircraft does not declare a stall angle rather than
	guessing one. An instrument that invents its own limit is worse than an
	instrument that stays quiet.
]]
local APPROACHING_MARGIN = math.rad(3)

function DebugHud.stallState(alpha: any, stallAlpha: any): string?
	if type(alpha) ~= "number" or type(stallAlpha) ~= "number" then
		return nil
	end
	if alpha ~= alpha or stallAlpha <= 0 then
		return nil
	end

	-- Magnitude, so an inverted or negative-g stall registers as one.
	local magnitude = math.abs(alpha)
	if magnitude >= stallAlpha then
		return "stall"
	end
	if magnitude >= stallAlpha - APPROACHING_MARGIN then
		return "approaching"
	end
	return nil
end

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

local function makeRow(parent: Instance, order: number, key: string, labelText: string): TextLabel
	local holder = Instance.new("Frame")
	holder.Name = key
	holder.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.LayoutOrder = order
	holder.Active = false
	holder.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(0, 58, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextSize = FONT_SIZE
	label.TextColor3 = COLOR_LABEL
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = labelText
	label.Active = false
	label.Parent = holder

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.Position = UDim2.fromOffset(58, 0)
	value.Size = UDim2.new(1, -58, 1, 0)
	value.BackgroundTransparency = 1
	value.Font = FONT
	value.TextSize = FONT_SIZE
	value.TextColor3 = COLOR_VALUE
	value.TextXAlignment = Enum.TextXAlignment.Left
	value.Text = "--"
	value.Active = false
	value.Parent = holder

	return value
end

local function makeHeader(parent: Instance, order: number, text: string)
	local label = Instance.new("TextLabel")
	label.Name = "Header_" .. text
	label.Size = UDim2.new(1, 0, 0, ROW_HEIGHT + 4)
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextSize = FONT_SIZE
	label.TextColor3 = COLOR_HEADER
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.LayoutOrder = order
	label.Active = false
	label.Parent = parent
end

--[[
	Build the panel.

	IgnoreGuiInset is left FALSE deliberately, which is what sidesteps the
	coordinate trap documented in the handoff. With the inset respected, this
	GUI's origin is already the top-left of the usable area below Roblox's top
	bar, so anchoring at a plain pixel offset needs no correction and cannot
	slide under the bar. The trap in the mouse code came from mixing that space
	with Camera.ViewportSize; nothing here mixes the two at all.
]]
function DebugHud.build(parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "FlightSimDebugHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 10
	gui.Enabled = false

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.fromOffset(PANEL_INSET, PANEL_INSET)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	-- Dark and mostly opaque so the numbers stay legible against bright sky,
	-- which is most of what the chase and free views look at.
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Active = false
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	rows = {}
	local order = 0

	makeHeader(panel, order, "FLIGHT")
	order += 1

	for _, entry in DebugHud.formatCore(nil, nil) do
		rows[entry.label] = makeRow(panel, order, entry.label, entry.label)
		order += 1
	end

	makeHeader(panel, order, "SURFACE   a     CL      CD")
	order += 1

	--[[
		Surface rows are created on demand rather than up front, because how
		many there are is a property of the aircraft, not of this panel. A
		different aeroplane with six surfaces must not need an edit here.
	]]
	rows.__surfaceParent = nil :: any
	local surfaceHolder = Instance.new("Frame")
	surfaceHolder.Name = "Surfaces"
	surfaceHolder.Size = UDim2.new(1, 0, 0, 0)
	surfaceHolder.AutomaticSize = Enum.AutomaticSize.Y
	surfaceHolder.BackgroundTransparency = 1
	surfaceHolder.BorderSizePixel = 0
	surfaceHolder.LayoutOrder = order
	surfaceHolder.Active = false
	surfaceHolder.Parent = panel

	local surfaceLayout = Instance.new("UIListLayout")
	surfaceLayout.SortOrder = Enum.SortOrder.LayoutOrder
	surfaceLayout.Parent = surfaceHolder

	gui.Parent = parent
	return gui
end

-- =========================================================================
-- UPDATE
-- =========================================================================

local function setRow(key: string, value: string, peak: string?)
	local label = rows[key]
	if not label then
		return
	end

	if peak then
		label.Text = value .. "  " .. peak
	else
		label.Text = value
	end
end

local function updateSurfaces(gui: ScreenGui, telemetry: any)
	local holder = gui:FindFirstChild("Panel")
	holder = holder and holder:FindFirstChild("Surfaces")
	if not holder then
		return
	end

	local data = DebugHud.formatSurfaces(telemetry)

	for i, entry in data do
		local row = holder:FindFirstChild("S" .. i) :: TextLabel?
		if not row then
			local created = Instance.new("TextLabel")
			created.Name = "S" .. i
			created.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			created.BackgroundTransparency = 1
			created.Font = FONT
			created.TextSize = FONT_SIZE
			created.TextColor3 = COLOR_VALUE
			created.TextXAlignment = Enum.TextXAlignment.Left
			created.LayoutOrder = i
			created.Active = false
			created.Parent = holder
			row = created
		end
		(row :: TextLabel).Text = string.format("%-10s %s", entry.name:sub(1, 10), entry.value)
	end

	-- Drop rows belonging to an aircraft with fewer surfaces than the last one.
	for _, child in holder:GetChildren() do
		if child:IsA("TextLabel") then
			local index = tonumber(child.Name:sub(2))
			if index and index > #data then
				child:Destroy()
			end
		end
	end
end

--[[
	One redraw. Public so the tests can drive it with synthetic telemetry.
]]
function DebugHud.render(telemetry: any, peakState: any?)
	local gui = screenGui
	if not gui then
		return
	end

	for _, entry in DebugHud.formatCore(telemetry, peakState) do
		setRow(entry.label, entry.value, entry.peak)
	end

	local g = rows.G
	if g then
		-- Peak text shares the row, so it is tinted by rewriting the whole
		-- label rather than by a second instance nobody would keep in sync.
		g.TextColor3 = if peakState and math.abs(peakState.loadFactor) > 3 then COLOR_PEAK else COLOR_VALUE
	end

	updateSurfaces(gui, telemetry)
end

local function onHeartbeat(dt: number)
	local gui = screenGui
	if not gui then
		return
	end

	local telemetry = FlightController.getTelemetry()
	local flying = telemetry ~= nil and FlightController.isFlying()

	--[[
		Hidden because the pilot switched it off is not the same as hidden
		because there is nothing to show, but the panel looks identical either
		way. Sampling stops in BOTH cases: peaks accumulated while the HUD was
		off would be shown as if they had just happened the moment it came back.
	]]
	if not flying or not hudWanted then
		if gui.Enabled then
			gui.Enabled = false
		end
		DebugHud.resetPeaks(peaks)
		return
	end

	if not gui.Enabled then
		gui.Enabled = true
	end

	-- Sampled every frame; drawn at INSTRUMENT_HZ. See the note on peaks.
	DebugHud.samplePeaks(peaks, telemetry)

	redrawAccumulator += dt
	local interval = 1 / Constants.SIM.INSTRUMENT_HZ
	if redrawAccumulator < interval then
		return
	end
	redrawAccumulator = 0

	DebugHud.render(telemetry, peaks)
	DebugHud.resetPeaks(peaks)
end

-- =========================================================================
-- LIFECYCLE
-- =========================================================================

--[[
	Show or hide the panel. Returns the new state.

	THE HUD IS NOW ALWAYS BUILT, and that is the change the toggle key forced.
	It used to return early from Init() when Constants.DEBUG.SHOW_PHYSICS_OVERLAY
	was false, which built nothing at all - so there was no panel for a key to
	switch back on, and the pilot's control would have worked in one direction
	only. The constant is now the STARTING state and nothing more.

	Pure enough to test directly: it touches one boolean, and the redraw loop
	reads it. No instance is created or destroyed by toggling, so a pilot
	flicking it on and off through a landing costs nothing.
]]
function DebugHud.setVisible(visible: boolean): boolean
	hudWanted = visible == true
	local gui = screenGui
	if gui and not hudWanted then
		-- Take it off the screen immediately rather than at the next redraw,
		-- which at 30 Hz is a visible lag on a key the pilot just pressed.
		gui.Enabled = false
	end
	return hudWanted
end

function DebugHud.toggle(): boolean
	return DebugHud.setVisible(not hudWanted)
end

function DebugHud.isVisible(): boolean
	return hudWanted
end

function DebugHud.Init()
	if initialised then
		return
	end

	initialised = true

	local playerGui = player:WaitForChild("PlayerGui")
	screenGui = DebugHud.build(playerGui)

	connection = RunService.Heartbeat:Connect(onHeartbeat)

	if Constants.DEBUG.ENABLED then
		print(string.format("[FlightSim:HUD] Debug HUD ready (starts %s, toggle with H)",
			if hudWanted then "shown" else "hidden"))
	end
end

function DebugHud.Shutdown()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	table.clear(rows)
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.UI.Instruments.DebugHud).runTests()

	The formatting is pure, so most of this needs no GUI at all. The build is
	exercised once against a real PlayerGui, because "does the panel actually
	appear with the right rows" is not a question arithmetic can answer.
]]
function DebugHud.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-50s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== DebugHud: verification ===")

	local built: ScreenGui? = nil

	local body = function()

	-- A synthetic telemetry block in pure SI, exactly as FlightModel writes it.
	local telemetry = {
		airspeedIndicated = 51.44, -- 100 kt exactly
		airspeedTrue = 61.73, -- 120 kt exactly
		altitude = 1234.5,
		verticalSpeed = 2.54, -- 500 fpm exactly
		alpha = math.rad(4.5),
		beta = math.rad(-2.25),
		loadFactor = 1.25,
		thrust = 1842.4,
		rpm = 2391.6,
		fuelKg = 152.8,
		density = 1.0555,
		dynamicPressure = 2334.2,
		--[[
			Deliberately no component landing on an exact .5, because
			string.format("%.0f", 1204.5) rounds half to EVEN and yields 1204,
			not 1205. A fixture sitting on that boundary tests the C library's
			rounding mode rather than anything in this module.
		]]
		force = Vector3.new(-12.3, 2104.7, -1842.1),
		torque = Vector3.new(310.2, -88.9, 1204.2),
		surfaces = {
			{ name = "WingLeft", alpha = math.rad(4.8), cl = 1.043, cd = 0.062 },
			{ name = "WingRight", alpha = math.rad(4.8), cl = 1.043, cd = 0.062 },
			{ name = "Stabilizer", alpha = math.rad(-1.2), cl = -0.104, cd = 0.011 },
			{ name = "Fin", alpha = 0, cl = 0, cd = 0.008 },
		},
	}

	local core = DebugHud.formatCore(telemetry, nil)
	local byLabel = {}
	for _, entry in core do
		byLabel[entry.label] = entry.value
	end

	-- 1. THE unit conversions. Wrong-way-round is the classic failure, and it
	--    is invisible unless the number is checked against a known input.
	record(
		"IAS converts m/s to knots",
		byLabel.IAS:find("100.0 kt") ~= nil,
		string.format("51.44 m/s -> '%s' (expected 100.0 kt)", byLabel.IAS)
	)
	record(
		"TAS converts m/s to knots",
		byLabel.TAS:find("120.0 kt") ~= nil,
		string.format("61.73 m/s -> '%s'", byLabel.TAS)
	)
	record(
		"Altitude stays in metres",
		byLabel.ALT:find("1234.5 m") ~= nil,
		string.format("'%s'", byLabel.ALT)
	)
	record(
		"Vertical speed shows m/s and ft/min",
		byLabel.VS:find("+2.54 m/s") ~= nil and byLabel.VS:find("+500 fpm") ~= nil,
		string.format("'%s'", byLabel.VS)
	)
	record(
		"Alpha converts radians to degrees",
		byLabel.AoA:find("+4.50 deg") ~= nil,
		string.format("%.4f rad -> '%s'", telemetry.alpha, byLabel.AoA)
	)
	record(
		"Beta keeps its sign",
		byLabel.BETA:find("-2.25 deg") ~= nil,
		string.format("'%s'", byLabel.BETA)
	)
	record("Load factor is in g", byLabel.G:find("+1.25 g") ~= nil, string.format("'%s'", byLabel.G))
	record("Thrust is in newtons", byLabel.THRUST:find("1842 N") ~= nil, string.format("'%s'", byLabel.THRUST))

	-- 2. Force components, with the signs that make them worth printing.
	record(
		"Force prints X, Y and Z separately with signs",
		byLabel.FORCE:find("X%s*-12") ~= nil
			and byLabel.FORCE:find("Y%s*%+2105") ~= nil
			and byLabel.FORCE:find("Z%s*-1842") ~= nil,
		string.format("'%s'", byLabel.FORCE)
	)
	record(
		"Torque prints X, Y and Z separately with signs",
		byLabel.TORQUE:find("X%s*%+310") ~= nil
			and byLabel.TORQUE:find("Y%s*%-89") ~= nil
			and byLabel.TORQUE:find("Z%s*%+1204") ~= nil,
		string.format("'%s'", byLabel.TORQUE)
	)

	-- 3. Surfaces -----------------------------------------------------------
	local surfaces = DebugHud.formatSurfaces(telemetry)
	record("One row per aerodynamic surface", #surfaces == 4, string.format("%d rows", #surfaces))
	record(
		"Surface rows carry alpha, CL and CD",
		surfaces[1].name == "WingLeft"
			and surfaces[1].value:find("%+4.8") ~= nil
			and surfaces[1].value:find("%+1.043") ~= nil
			and surfaces[1].value:find("0.062") ~= nil,
		string.format("'%s %s'", surfaces[1].name, surfaces[1].value)
	)
	record(
		"A stalled wing reads differently from the other side",
		(function()
			local asym = table.clone(telemetry)
			asym.surfaces = {
				{ name = "WingLeft", alpha = math.rad(17.2), cl = 0.81, cd = 0.35 },
				{ name = "WingRight", alpha = math.rad(9.4), cl = 1.44, cd = 0.09 },
			}
			local s = DebugHud.formatSurfaces(asym)
			return s[1].value ~= s[2].value
		end)(),
		"asymmetry is visible, which is the point of per-surface rows"
	)

	-- 4. Peaks ---------------------------------------------------------------
	local p = DebugHud.newPeaks()
	DebugHud.samplePeaks(p, { loadFactor = 1.0, force = Vector3.new(0, 1000, 0) })
	DebugHud.samplePeaks(p, { loadFactor = 3.9, force = Vector3.new(0, 21455, 0) })
	DebugHud.samplePeaks(p, { loadFactor = 1.1, force = Vector3.new(0, 900, 0) })
	record(
		"Peak load factor survives a one-frame spike",
		math.abs(p.loadFactor - 3.9) < 1e-6,
		string.format("peak %.2f g from samples 1.0 / 3.9 / 1.1", p.loadFactor)
	)
	record(
		"Peak force survives a one-frame spike",
		math.abs(p.forceMagnitude - 21455) < 1,
		string.format("peak %.0f N", p.forceMagnitude)
	)

	-- A hard negative excursion is a peak too; tracking only positives would
	-- hide exactly the pushover that breaks an aeroplane.
	local negative = DebugHud.newPeaks()
	DebugHud.samplePeaks(negative, { loadFactor = -2.4, force = Vector3.zero })
	record(
		"Negative g registers as a peak",
		math.abs(negative.loadFactor + 2.4) < 1e-6,
		string.format("peak %.2f g", negative.loadFactor)
	)

	--[[
		Alpha needs a peak for the same reason g does, and did not have one.

		Measured on a real stall entry: alpha sat between 8 and 14 degrees
		through the pull, touched 18.6 at the break, and was back under 3 within
		a second and a half. At 30 Hz the single number worth seeing was the one
		most likely to be missed - which is what made the readout look stuck.
	]]
	local stallPeak = DebugHud.newPeaks()
	DebugHud.samplePeaks(stallPeak, { alpha = math.rad(11.2) })
	DebugHud.samplePeaks(stallPeak, { alpha = math.rad(18.6) }) -- the break
	DebugHud.samplePeaks(stallPeak, { alpha = math.rad(2.4) })
	record(
		"Peak alpha survives the stall break",
		math.abs(math.deg(stallPeak.alpha) - 18.6) < 0.01,
		string.format("peak %.1f deg from samples 11.2 / 18.6 / 2.4", math.deg(stallPeak.alpha))
	)

	DebugHud.resetPeaks(p)
	record(
		"Peaks reset after a redraw",
		p.loadFactor == 0 and p.forceMagnitude == 0 and p.alpha == 0,
		"all three zero"
	)

	-- 4b. Stall marking --------------------------------------------------------
	--[[
		THE thing the pilot asked for. Alpha alone cannot say whether the number
		in front of you is fine or a departure, and without the wing's stall
		angle beside it the readout is just a number that moves.
	]]
	local STALL_AT = math.rad(16)
	record(
		"Well below the stall says nothing at all",
		DebugHud.stallState(math.rad(4), STALL_AT) == nil,
		"4 deg against a 16 deg stall -> nil"
	)
	record(
		"Approaching the stall warns before it happens",
		DebugHud.stallState(math.rad(14), STALL_AT) == "approaching",
		"14 deg -> approaching (warning starts 3 deg early)"
	)
	record(
		"Past the stall angle says STALL",
		DebugHud.stallState(math.rad(18.6), STALL_AT) == "stall",
		"18.6 deg, the measured break -> stall"
	)
	--[[
		Magnitude, not sign: an aeroplane can stall inverted or under negative g,
		and a check that only looked at positive alpha would stay silent through
		exactly the departure worth warning about.
	]]
	record(
		"A negative-alpha stall registers too",
		DebugHud.stallState(math.rad(-18), STALL_AT) == "stall",
		"-18 deg -> stall"
	)
	--[[
		An aircraft that declares no stall angle gets NO marking rather than a
		guessed one. An instrument that invents its own limit is worse than one
		that stays quiet.
	]]
	record(
		"No stall angle means no marking, not a guessed one",
		DebugHud.stallState(math.rad(30), nil) == nil and DebugHud.stallState(math.rad(30), 0) == nil,
		"nil and 0 both yield no marking"
	)
	record(
		"A NaN alpha does not claim a stall",
		DebugHud.stallState(0 / 0, STALL_AT) == nil,
		"NaN -> nil"
	)

	-- And it has to reach the rendered line, not just the predicate.
	local stalled = table.clone(telemetry)
	stalled.alpha = math.rad(18.6)
	stalled.stallAlpha = STALL_AT
	local stalledRows = DebugHud.formatCore(stalled)
	local aoaRow
	for _, row in stalledRows do
		if row.label == "AoA" then aoaRow = row end
	end
	record(
		"The AoA line actually shows the stall",
		aoaRow ~= nil and string.find(aoaRow.value, "STALL") ~= nil,
		aoaRow and aoaRow.value or "no AoA row"
	)

	-- 4c. Attitude is not angle of attack ---------------------------------------
	--[[
		The distinction that made the readout look broken. In a climbing pull the
		nose can be 20 degrees up with alpha at 8, because the flight path curves
		to follow it. Both are now on the panel, adjacent, so the difference is
		legible instead of mysterious.
	]]
	local climbing = table.clone(telemetry)
	climbing.alpha = math.rad(8.7)
	climbing.pitchAttitude = math.rad(20.8)
	climbing.bankAngle = math.rad(-12.5)
	local climbRows = DebugHud.formatCore(climbing)
	local aoaText, attText
	for _, row in climbRows do
		if row.label == "AoA" then aoaText = row.value end
		if row.label == "ATT" then attText = row.value end
	end
	record(
		"Attitude is shown, and separately from AoA",
		attText ~= nil and aoaText ~= nil and attText ~= aoaText
			and string.find(attText, "20.80") ~= nil and string.find(aoaText, "8.70") ~= nil,
		string.format("AoA '%s' vs ATT '%s'", tostring(aoaText), tostring(attText))
	)
	record(
		"Bank angle appears on the attitude line",
		attText ~= nil and string.find(attText, "-12.5") ~= nil,
		tostring(attText)
	)

	-- 5. Garbage in ----------------------------------------------------------
	--[[
		A NaN must be REPORTED, not hidden. It is the most valuable thing this
		panel can show, because it means the physics has gone numerically bad -
		and Roblox sanitises NaN inside property setters, so the HUD may be the
		only place it is ever visible.
	]]
	local nan = 0 / 0
	record("NaN is displayed as NaN, not hidden", DebugHud.num(nan, "%.2f") == "NaN", DebugHud.num(nan, "%.2f"))
	record("Infinity is displayed", DebugHud.num(math.huge, "%.2f") == "+INF", DebugHud.num(math.huge, "%.2f"))
	record("A missing value reads as --", DebugHud.num(nil, "%.2f") == "--", DebugHud.num(nil, "%.2f"))

	local emptyOk = pcall(function()
		DebugHud.formatCore(nil, nil)
		DebugHud.formatCore({}, nil)
		DebugHud.formatSurfaces({})
		DebugHud.formatSurfaces(nil)
	end)
	record("Empty or absent telemetry does not error", emptyOk, "formatted without throwing")

	-- 6. The panel itself ------------------------------------------------------
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		built = DebugHud.build(playerGui)
		local gui = built :: ScreenGui
		local panel = gui:FindFirstChild("Panel") :: Frame

		record("Panel builds", panel ~= nil, panel and "Panel present" or "missing")
		record(
			"Starts hidden until the pilot is flying",
			not gui.Enabled,
			string.format("Enabled = %s", tostring(gui.Enabled))
		)
		record(
			"Respects the GUI inset instead of hiding under the top bar",
			not gui.IgnoreGuiInset,
			"IgnoreGuiInset = false"
		)

		--[[
			Nothing may absorb the pointer. The cursor is the yoke and covers
			the whole screen, so an Active element here could eat input the
			flight controls depend on.
		]]
		local activeCount = 0
		for _, d in gui:GetDescendants() do
			if (d:IsA("GuiObject") and d.Active) or d:IsA("GuiButton") then
				activeCount += 1
			end
		end
		record(
			"Nothing in the HUD can swallow mouse input",
			activeCount == 0,
			string.format("%d active or clickable element(s)", activeCount)
		)

		record(
			"A row exists for every core value",
			(function()
				for _, entry in DebugHud.formatCore(nil, nil) do
					if not rows[entry.label] then
						return false
					end
				end
				return true
			end)(),
			string.format("%d core rows", #DebugHud.formatCore(nil, nil))
		)
	else
		record("Panel builds", false, "no PlayerGui - run this in the Client datamodel, in Play")
	end

	end

	local ok, err = pcall(body)

	if built then
		built:Destroy()
	end
	-- The suite builds a panel and repoints the shared row table at it; clear
	-- it so a live HUD is never left pointing at destroyed labels.
	if screenGui == nil then
		table.clear(rows)
	end

	if not ok then
		allPassed = false
		record("Suite completed without erroring", false, tostring(err))
	end

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return DebugHud
