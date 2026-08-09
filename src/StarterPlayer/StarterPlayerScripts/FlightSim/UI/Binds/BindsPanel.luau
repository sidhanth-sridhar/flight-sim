--!strict
--[[
	BindsPanel
	----------
	The in-game controls list: every action and the key that does it. Phase 4c.

	WHY IT EXISTS NOW AND NOT BEFORE
	--------------------------------
	Nineteen bindings were memorable. Phase 4c added twenty-two more - two trims,
	a mixture, a fuel valve, an ignition, a starter, three masters, a breaker,
	five lights, four environmental switches - and forty-one is not a keyboard
	anybody holds in their head. A control the pilot cannot find is a control
	that is not there, so the aeroplane needs its own reference.

	⚠️ IT IS BUILT FROM InputController.DEFAULT_BINDINGS, NOT FROM A COPY OF IT.
	That is the whole design constraint and it is not a stylistic preference: a
	second hand-written list is a list that goes stale, and a controls reference
	that lies is worse than none at all - the pilot trusts it and concludes the
	feature is broken. `rows()` walks the live table, so a binding that is added,
	removed or rebound appears here with no edit, and a test asserts the two
	agree exactly.

	⚠️ NOTHING HERE MAY ABSORB INPUT. §7 states it flatly: the cursor is the
	yoke, so an on-screen button IS a flight control. This panel is safe to
	show anywhere - including mid-flight, which is exactly when a pilot needs
	it - precisely because it is `TextLabel`s and nothing else. No `Active`, no
	`GuiButton`, no `Selectable`. A clickable version is forbidden, and the
	test that counts interactive descendants is what keeps it that way.

	This is the same arrangement DebugHud has (§6i), for the same reasons, and
	it is owned by UIController for the same reason again: the bootstrap only
	scans `Controllers/`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local InputController = require(script.Parent.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

local BindsPanel = {}

-- =========================================================================
-- APPEARANCE
-- =========================================================================

local PANEL_WIDTH = 640
local ROW_HEIGHT = 16
local FONT_SIZE = 13
local COLUMN_WIDTH = 300

-- Monospace, so the key column lines up. Same reasoning as the debug HUD.
local FONT = Enum.Font.Code

local COLOR_BACKDROP = Color3.fromRGB(16, 20, 26)
local COLOR_ACTION = Color3.fromRGB(206, 214, 224)
local COLOR_KEY = Color3.fromRGB(255, 210, 120)
local COLOR_SECTION = Color3.fromRGB(120, 190, 255)
local COLOR_DIM = Color3.fromRGB(140, 152, 166)

-- =========================================================================
-- GROUPING
-- =========================================================================

--[[
	Which section each action belongs in, and the order sections are drawn.

	⚠️ THIS IS PRESENTATION ONLY AND IS NEVER THE SOURCE OF TRUTH. An action
	that is not named here is NOT dropped - it falls into "Other", where it is
	visible and obviously unfiled. That fallback is the whole safety property:
	the failure mode of a hand-maintained grouping is a binding that silently
	vanishes from the reference, and this makes that impossible.
]]
local SECTION_ORDER = { "Flight", "Engine", "Fuel & Ignition", "Electrical", "Lights", "Cabin", "View", "Panels", "Other" }

local SECTION_OF: { [string]: string } = {
	ThrottleUp = "Engine", ThrottleDown = "Engine", Brake = "Flight",
	YawLeft = "Flight", YawRight = "Flight",
	FlapsDown = "Flight", FlapsUp = "Flight",
	TrimNoseUp = "Flight", TrimNoseDown = "Flight",
	RudderTrimLeft = "Flight", RudderTrimRight = "Flight",
	GearToggle = "Flight", AltitudeHold = "Flight",

	EngineToggle = "Engine", StarterEngage = "Engine",
	MixtureRich = "Engine", MixtureLean = "Engine",

	FuelSelectorUp = "Fuel & Ignition", FuelSelectorDown = "Fuel & Ignition",
	MagnetosUp = "Fuel & Ignition", MagnetosDown = "Fuel & Ignition",

	BatteryMaster = "Electrical", AlternatorMaster = "Electrical",
	AvionicsMaster = "Electrical", BreakerReset = "Electrical",

	LightBeacon = "Lights", LightNav = "Lights", LightStrobe = "Lights",
	LightTaxi = "Lights", LightLanding = "Lights",

	CabinHeat = "Cabin", CabinVent = "Cabin", CabinDefrost = "Cabin",
	PitotHeat = "Cabin",

	ViewCycle = "View", ViewToggle = "View", CameraHold = "View",

	ToggleHud = "Panels", ToggleTablet = "Panels", ToggleBinds = "Panels",
	ResetAircraft = "Panels", Pause = "Panels",
}

--[[
	A human label for each action, because `FuelSelectorDown` is a symbol and
	"Fuel selector <- (OFF)" is a control.

	Same fallback rule as the sections: an action with no label shows its own
	name rather than a blank, so a missing entry is visible rather than silent.
]]
local LABEL_OF: { [string]: string } = {
	ThrottleUp = "Throttle open", ThrottleDown = "Throttle closed",
	YawLeft = "Rudder left", YawRight = "Rudder right",
	FlapsDown = "Flaps down one detent", FlapsUp = "Flaps up one detent",
	Brake = "Wheel brakes", GearToggle = "Landing gear",
	TrimNoseUp = "Pitch trim nose up", TrimNoseDown = "Pitch trim nose down",
	RudderTrimLeft = "Rudder trim left", RudderTrimRight = "Rudder trim right",
	AltitudeHold = "Altitude hold / wings level",

	EngineToggle = "Engine on / off (quick)", StarterEngage = "Starter (hold)",
	MixtureRich = "Mixture rich", MixtureLean = "Mixture lean (cutoff stops it)",

	FuelSelectorDown = "Fuel selector toward OFF", FuelSelectorUp = "Fuel selector toward RIGHT",
	MagnetosDown = "Magnetos toward OFF", MagnetosUp = "Magnetos toward BOTH",

	BatteryMaster = "Battery master", AlternatorMaster = "Alternator master",
	AvionicsMaster = "Avionics master", BreakerReset = "Reset circuit breaker",

	LightBeacon = "Beacon", LightNav = "Navigation lights", LightStrobe = "Strobes",
	LightTaxi = "Taxi light", LightLanding = "Landing light",

	CabinHeat = "Cabin heat", CabinVent = "Cabin vent", CabinDefrost = "Windscreen defrost",
	PitotHeat = "Pitot heat",

	ViewCycle = "Cycle view", ViewToggle = "Inside / outside", CameraHold = "Look around (hold)",

	ToggleHud = "Debug HUD", ToggleTablet = "Flight tablet", ToggleBinds = "This list",
	ResetAircraft = "Reset aircraft", Pause = "Pause",
}

--[[
	A readable name for a KeyCode.

	`Enum.KeyCode.LeftBracket.Name` is "LeftBracket", which is not what is
	printed on the key. The pilot is looking for the symbol.
]]
local KEY_SYMBOL: { [string]: string } = {
	LeftBracket = "[", RightBracket = "]",
	Comma = ",", Period = ".", Slash = "/", BackSlash = "\\",
	Minus = "-", Equals = "=", Backquote = "`",
	Semicolon = ";", Quote = "'",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
	Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	Return = "Enter", Escape = "Esc",
}

function BindsPanel.keyName(keyCode: Enum.KeyCode): string
	local name = keyCode.Name
	return KEY_SYMBOL[name] or name
end

-- =========================================================================
-- THE LIST - pure
-- =========================================================================

export type Row = {
	section: string,
	action: string,
	label: string,
	key: string,
}

--[[
	Every binding, grouped and ordered, read from the LIVE table.

	`bindings` defaults to `InputController.DEFAULT_BINDINGS` - the same table
	the game actually binds from - so a rebind through `InputController.rebind`
	shows up here immediately. Passing one explicitly is for the tests and for a
	future per-player settings screen.

	Sorted within a section by action name so the list is stable between
	sessions; `pairs()` order over a table is not.
]]
function BindsPanel.rows(bindings: { [string]: Enum.KeyCode }?): { Row }
	local source = bindings or InputController.DEFAULT_BINDINGS

	local bySection: { [string]: { Row } } = {}
	for action, keyCode in source do
		local section = SECTION_OF[action] or "Other"
		bySection[section] = bySection[section] or {}
		table.insert(bySection[section], {
			section = section,
			action = action,
			label = LABEL_OF[action] or action,
			key = BindsPanel.keyName(keyCode),
		})
	end

	local rows: { Row } = {}
	for _, section in SECTION_ORDER do
		local group = bySection[section]
		if group then
			table.sort(group, function(a, b)
				return a.action < b.action
			end)
			for _, row in group do
				table.insert(rows, row)
			end
			bySection[section] = nil
		end
	end

	--[[
		Anything in a section SECTION_ORDER does not name still gets drawn, at
		the end. Unreachable while the two agree - and that is the point: it is
		the guard against them not agreeing.
	]]
	for _, group in bySection do
		for _, row in group do
			table.insert(rows, row)
		end
	end

	return rows
end

-- =========================================================================
-- BUILDING
-- =========================================================================

local screenGui: ScreenGui? = nil
local visible = false

local function textLine(parent: Instance, text: string, color: Color3, x: number, y: number, width: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(width, ROW_HEIGHT)
	label.Position = UDim2.fromOffset(x, y)
	label.Font = FONT
	label.Text = text
	label.TextColor3 = color
	label.TextSize = FONT_SIZE
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	--[[
		⚠️ THE THREE LINES THAT MAKE THIS SAFE TO SHOW IN FLIGHT. A label that
		is Active or Selectable can take input, and the cursor is the yoke.
	]]
	label.Active = false
	label.Selectable = false
	label.Parent = parent
	return label
end

--[[
	Build the list into any parent. Knows nothing about a screen, so it can be
	mounted on a kneeboard during the 3D pass - same split §19 draws for the
	instrument panel.
]]
function BindsPanel.buildPanel(parent: Instance, bindings: { [string]: Enum.KeyCode }?): Frame
	local rows = BindsPanel.rows(bindings)

	--[[
		Two columns, because forty-one rows in one column is taller than the
		screen. Split at the section boundary nearest the halfway point so a
		section is never cut in two.
	]]
	local perColumn = math.ceil(#rows / 2)
	local splitAt = perColumn
	for i = perColumn, math.min(#rows, perColumn + 8) do
		if rows[i] and rows[i + 1] and rows[i].section ~= rows[i + 1].section then
			splitAt = i
			break
		end
	end

	-- Height is the taller column plus its section headings and the title.
	local tallest = math.max(splitAt, #rows - splitAt)
	local height = (tallest + #SECTION_ORDER + 4) * ROW_HEIGHT

	local panel = Instance.new("Frame")
	panel.Name = "BindsPanel"
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, height)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = COLOR_BACKDROP
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Active = false
	panel.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel

	textLine(panel, "CONTROLS", COLOR_SECTION, 14, 8, 200)
	textLine(panel, string.format("%d bindings  -  K to close", #rows), COLOR_DIM, PANEL_WIDTH - 250, 8, 240)

	local columnX = { 14, 14 + COLUMN_WIDTH + 20 }
	local columnY = { ROW_HEIGHT * 2 + 8, ROW_HEIGHT * 2 + 8 }
	local lastSection = { "", "" }

	for index, row in rows do
		local col = if index <= splitAt then 1 else 2

		if row.section ~= lastSection[col] then
			columnY[col] += if lastSection[col] == "" then 0 else ROW_HEIGHT // 2
			textLine(panel, row.section:upper(), COLOR_SECTION, columnX[col], columnY[col], COLUMN_WIDTH)
			columnY[col] += ROW_HEIGHT
			lastSection[col] = row.section
		end

		textLine(panel, row.label, COLOR_ACTION, columnX[col], columnY[col], COLUMN_WIDTH - 70)
		local key = textLine(panel, row.key, COLOR_KEY, columnX[col] + COLUMN_WIDTH - 68, columnY[col], 64)
		key.TextXAlignment = Enum.TextXAlignment.Right
		columnY[col] += ROW_HEIGHT
	end

	return panel
end

function BindsPanel.Init()
	if screenGui then
		return
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "FlightBinds"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 22
	gui.Enabled = false
	gui.Parent = playerGui

	BindsPanel.buildPanel(gui)

	screenGui = gui
	visible = false
end

function BindsPanel.setVisible(state: boolean)
	visible = state
	if screenGui then
		screenGui.Enabled = state
	end
end

function BindsPanel.toggle(): boolean
	BindsPanel.setVisible(not visible)
	return visible
end

function BindsPanel.isVisible(): boolean
	return visible
end

function BindsPanel.Shutdown()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	visible = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

function BindsPanel.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-56s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== BindsPanel: verification ===")

	local rows = BindsPanel.rows()

	--[[
		⚠️ THE CHECK THIS WHOLE MODULE EXISTS TO PASS. The list must be the
		bindings table - every action exactly once, no extras, no omissions. A
		controls reference that disagrees with the controls is worse than no
		reference at all, because the pilot believes it.
	]]
	local bindingCount = 0
	local seen: { [string]: boolean } = {}
	for _ in InputController.DEFAULT_BINDINGS do
		bindingCount += 1
	end

	local duplicates = 0
	for _, row in rows do
		if seen[row.action] then
			duplicates += 1
		end
		seen[row.action] = true
	end

	local missing = {}
	for action in InputController.DEFAULT_BINDINGS do
		if not seen[action] then
			table.insert(missing, action)
		end
	end

	record(
		"Every binding appears exactly once",
		#rows == bindingCount and duplicates == 0 and #missing == 0,
		string.format("%d rows against %d bindings, %d duplicate(s), missing: %s",
			#rows, bindingCount, duplicates,
			#missing == 0 and "none" or table.concat(missing, ", "))
	)

	--[[
		And the KEY each row shows is the key actually bound. Comparing counts
		would pass a list that had every action against the wrong keys.
	]]
	local wrongKey = nil
	for _, row in rows do
		local bound = InputController.DEFAULT_BINDINGS[row.action]
		if bound and BindsPanel.keyName(bound) ~= row.key then
			wrongKey = string.format("%s shows %s, bound to %s", row.action, row.key, bound.Name)
		end
	end
	record(
		"Every row shows the key that is actually bound",
		wrongKey == nil,
		wrongKey or string.format("all %d rows agree with the bindings table", #rows)
	)

	--[[
		THE SELF-REFERENCE. A controls list that does not tell you how to close
		it is a controls list you have to guess your way out of - and since it
		is drawn over the windscreen, guessing happens in flight.
	]]
	local hasOwnKey = false
	for _, row in rows do
		if row.action == "ToggleBinds" then
			hasOwnKey = row.key == BindsPanel.keyName(InputController.DEFAULT_BINDINGS.ToggleBinds)
		end
	end
	record(
		"The list contains its own toggle key",
		hasOwnKey,
		string.format("ToggleBinds -> %s", BindsPanel.keyName(InputController.DEFAULT_BINDINGS.ToggleBinds))
	)

	--[[
		A rebind must reach the list, which is the property that makes reading
		the live table rather than a copy worth doing.
	]]
	local rebound = table.clone(InputController.DEFAULT_BINDINGS)
	rebound.Brake = Enum.KeyCode.N
	local reboundRows = BindsPanel.rows(rebound)
	local brakeKey = nil
	for _, row in reboundRows do
		if row.action == "Brake" then
			brakeKey = row.key
		end
	end
	record(
		"A rebound key shows the new binding, not the old one",
		brakeKey == "N",
		string.format("Brake -> %s", tostring(brakeKey))
	)

	--[[
		An action nobody has filed must still be VISIBLE. The failure mode of a
		hand-maintained grouping is a binding that quietly vanishes from the
		reference; "Other" is what makes that impossible.
	]]
	local unfiled = table.clone(InputController.DEFAULT_BINDINGS)
	unfiled.SomethingNobodyFiled = Enum.KeyCode.F12
	local unfiledRows = BindsPanel.rows(unfiled)
	local foundUnfiled = false
	for _, row in unfiledRows do
		if row.action == "SomethingNobodyFiled" then
			foundUnfiled = row.section == "Other"
		end
	end
	record(
		"An ungrouped action still appears, under Other",
		foundUnfiled and #unfiledRows == #rows + 1,
		"visible rather than silently dropped"
	)

	-- Symbols, because "LeftBracket" is not what is printed on the key.
	record(
		"Punctuation keys read as the symbol on the key",
		BindsPanel.keyName(Enum.KeyCode.LeftBracket) == "["
			and BindsPanel.keyName(Enum.KeyCode.Comma) == ","
			and BindsPanel.keyName(Enum.KeyCode.One) == "1",
		"[ , 1"
	)
	record(
		"...and an ordinary letter reads as itself",
		BindsPanel.keyName(Enum.KeyCode.K) == "K",
		"K"
	)

	-- Sections are ordered, not shuffled.
	local sectionsSeen = {}
	local orderOk = true
	local lastIndex = 0
	for _, row in rows do
		if not sectionsSeen[row.section] then
			sectionsSeen[row.section] = true
			local index = table.find(SECTION_ORDER, row.section) or math.huge
			if index < lastIndex then
				orderOk = false
			end
			lastIndex = index
		end
	end
	record(
		"Sections are drawn in a fixed order, not pairs() order",
		orderOk,
		"stable between sessions"
	)

	-- ---- The built panel --------------------------------------------------
	local harness = Instance.new("Folder")
	harness.Name = "__BindsPanelTestHarness"
	harness.Parent = ReplicatedStorage

	local ok, err = pcall(function()
		local panel = BindsPanel.buildPanel(harness)

		--[[
			⚠️ THE SAFETY PROPERTY, COUNTED RATHER THAN TRUSTED. §7: an
			on-screen button IS a flight control in this game. This panel is
			shown in flight, so a single GuiButton or Active element anywhere in
			it would be a yoke input the pilot did not ask for.
		]]
		local interactive = {}
		for _, d in panel:GetDescendants() do
			if d:IsA("GuiButton") then
				table.insert(interactive, d:GetFullName() .. " (GuiButton)")
			elseif d:IsA("GuiObject") and d.Active then
				table.insert(interactive, d:GetFullName() .. " (Active)")
			end
		end
		record(
			"Nothing in the panel can absorb a click",
			#interactive == 0 and not panel.Active,
			#interactive == 0 and "no GuiButton, nothing Active" or table.concat(interactive, ", ")
		)

		--[[
			Every row reached the screen. A panel that silently drew half the
			list would pass every pure check above it.
		]]
		local drawn = 0
		for _, d in panel:GetDescendants() do
			if d:IsA("TextLabel") and d.TextColor3 == COLOR_KEY then
				drawn += 1
			end
		end
		record(
			"Every binding is actually drawn, not just computed",
			drawn == #rows,
			string.format("%d key labels on the panel against %d rows", drawn, #rows)
		)
	end)

	harness:Destroy()

	if not ok then
		allPassed = false
		record("The panel builds without erroring", false, tostring(err))
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

return BindsPanel
