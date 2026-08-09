--!strict
--[[
	Tablet
	------
	The flight tablet: pick an aircraft, a departure field and a destination,
	and see what the leg looks like before flying it.

	GRAYBOX (§44). This is a SCREEN PANEL, not a 3D slate mounted on the
	glareshield. All aircraft and cockpit 3D modelling is postponed until v1 is
	feature-complete, so the tablet is drawn the way the six-pack is drawn today:
	flat, on the screen, in the panel style already established. It is the
	feature that matters, and the feature works identically either way.

	WHAT IS PURE AND WHAT IS NOT
	----------------------------
	Everything that DECIDES something is a pure function of plain tables -
	the default selection, which plan a selection names, and the exact rows a
	pilot reads. Only build()/render() touch a Roblox instance. That split is the
	same one AirportService draws between its data and its geometry, and it is
	what lets runTests() assert the strings on the screen without a screen.

	IT IS THE FIRST THING IN THIS PROJECT THAT MAY EAT A CLICK
	----------------------------------------------------------
	Every other piece of UI here is inert on purpose: the cursor is the yoke, so
	a GuiButton anywhere on screen is a flight control (§7, §6i). The tablet
	genuinely needs buttons - no key can choose among airports - which is why it
	is gated rather than decorated. TabletController owns that gate; see
	InputController.tabletMayOpen for the pilot's decision and the reasoning.

	The consequence for THIS file is one rule, and it is why the panel is built
	hidden and only enabled by the controller: nothing in here may be `Active` or
	a `GuiButton` while the tablet is closed. A ScreenGui with `Enabled = false`
	absorbs nothing at all, so the rule is satisfied by the visibility mechanism
	rather than by remembering to disable each button.

	WHERE THE DATA COMES FROM
	-------------------------
	Airports arrive over RequestAirportList as AirportService's own snapshot -
	including the flight plans, which are that module's arithmetic and not a
	second copy of it. Aircraft come straight out of Aircraft/Registry.luau,
	which is in ReplicatedStorage and therefore already on this machine.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Units = require(FlightSim.Shared.Units)
local Registry = require(FlightSim.Aircraft.Registry)

local Tablet = {}

-- =========================================================================
-- APPEARANCE
-- =========================================================================

--[[
	Fixed pixels, not scale, and for the reason §19 records for the instrument
	panel: a panel measured in pixels can be parented into a SurfaceGui on a real
	cockpit slate later without a single number changing. buildPanel() knows
	nothing about a screen; build() is the throwaway ScreenGui wrapper around it.
]]
local PANEL_WIDTH = 620
local PANEL_HEIGHT = 420
local PADDING = 16
local ROW_HEIGHT = 26
local COLUMN_GAP = 12
local HEADER_HEIGHT = 34
local SUMMARY_HEIGHT = 132

-- Monospace, for the same reason the debug HUD is: the summary is a column of
-- numbers that change, and a proportional font makes the whole block twitch.
local FONT = Enum.Font.Code

local COLOR_BACKDROP = Color3.fromRGB(18, 22, 28)
local COLOR_PANEL = Color3.fromRGB(28, 34, 42)
local COLOR_ROW = Color3.fromRGB(38, 46, 56)
local COLOR_ROW_PICKED = Color3.fromRGB(38, 92, 140)
local COLOR_TEXT = Color3.fromRGB(228, 236, 244)
local COLOR_DIM = Color3.fromRGB(146, 158, 172)
local COLOR_HEADER = Color3.fromRGB(120, 190, 255)
local COLOR_GO = Color3.fromRGB(46, 132, 78)
local COLOR_WARN = Color3.fromRGB(226, 152, 72)

-- =========================================================================
-- TYPES
-- =========================================================================

export type Selection = {
	from: string?,
	to: string?,
	aircraftId: string,
}

-- The payload AirportService.tabletSnapshot() produces. Restated here rather
-- than imported, because that module is server-only and this one cannot see it -
-- which is the whole reason the snapshot exists.
export type Snapshot = {
	airports: { any },
	plans: { [string]: { [string]: any } },
}

-- =========================================================================
-- SELECTION - pure
-- =========================================================================

--[[
	Which aircraft the picker offers, as { id, name } in registry order.

	Registry.ids() is already sorted, so the list cannot shuffle between
	sessions. Today it is one entry; the picker is written against the list
	rather than against "the 172" so that Phase 5's jet needs no edit here.
]]
function Tablet.aircraftList(): { { id: string, name: string } }
	local list = {}
	for _, id in Registry.ids() do
		local definition = Registry.get(id)
		table.insert(list, {
			id = id,
			-- A definition with no name is a bug elsewhere, not a reason for the
			-- tablet to be blank.
			name = if definition and type(definition.name) == "string" then definition.name else id,
		})
	end
	return list
end

--[[
	Which field in the snapshot is nearest a point, horizontally.

	⚠️ THIS IS NOT AircraftService's SPAWN DECISION AND MUST NOT BE CONFUSED WITH
	IT. AirportService.nearestAirport() decides where a pilot actually spawns
	(§24); it is server-side and it stays the authority. This one decides only
	which row the DEPARTURE column opens highlighted on, and the server re-reads
	the departure field off the flight request anyway.

	Horizontal, for the same reason §24 gives: an aeroplane 400 m above Ridge is
	at Ridge, not somewhere between the two fields.

	Returns nil for an empty snapshot rather than guessing, which
	defaultSelection() answers by falling back to the first field.
]]
function Tablet.nearestAirport(snapshot: Snapshot?, position: Vector3?): string?
	if not snapshot or not position or #snapshot.airports == 0 then
		return nil
	end

	local bestId, bestDistance = nil, math.huge
	for _, airport in snapshot.airports do
		local flat = Vector3.new(airport.position.X - position.X, 0, airport.position.Z - position.Z)
		if flat.Magnitude < bestDistance then
			bestId, bestDistance = airport.id, flat.Magnitude
		end
	end

	return bestId
end

--[[
	The selection the tablet opens on.

	Departure is the field the pilot is AT, which is the one useful default:
	they are standing on it, and §24 already spawned them there. Destination is
	the first field that is not the departure - deliberately not nil, because a
	tablet that opens with no destination shows no distance and no bearing, and
	the first thing a pilot would do is pick one anyway.

	`nearestId` may be nil (no aircraft, no character, nothing known yet), in
	which case the first field in the snapshot is used. The snapshot is sorted by
	id, so "first" is stable rather than whatever the network happened to hand
	over.
]]
function Tablet.defaultSelection(snapshot: Snapshot?, nearestId: string?): Selection
	local selection: Selection = {
		from = nil,
		to = nil,
		aircraftId = Registry.DEFAULT_ID,
	}

	if not snapshot or #snapshot.airports == 0 then
		return selection
	end

	local ids = {}
	for _, airport in snapshot.airports do
		table.insert(ids, airport.id)
	end

	-- Only trust the nearest field if the snapshot actually contains it.
	selection.from = ids[1]
	if nearestId then
		for _, id in ids do
			if id == nearestId then
				selection.from = nearestId
			end
		end
	end

	for _, id in ids do
		if id ~= selection.from then
			selection.to = id
			break
		end
	end

	return selection
end

--[[
	Choosing a field, with the one rule the pickers have to enforce.

	A leg from a field to itself is not a leg - AirportService.flightPlan()
	returns nil for it and the server refuses it. Rather than let the pilot pick
	an impossible pair and then be told off, picking a departure that is already
	the destination SWAPS them. That is what the pilot means: they have decided
	to fly the other way.

	Returns a new table rather than mutating, so the caller can compare before
	and after and decide whether anything needs redrawing.
]]
function Tablet.choose(selection: Selection, field: string, id: string): Selection
	local next: Selection = {
		from = selection.from,
		to = selection.to,
		aircraftId = selection.aircraftId,
	}

	if field == "aircraftId" then
		next.aircraftId = id
		return next
	end

	if field == "from" then
		if selection.to == id then
			next.to = selection.from
		end
		next.from = id
	elseif field == "to" then
		if selection.from == id then
			next.from = selection.to
		end
		next.to = id
	end

	return next
end

--[[
	The plan a selection names, or nil.

	A LOOKUP, NOT A CALCULATION, and that is the point: the arithmetic is
	AirportService's, done once on the server, and the tablet only ever presents
	it. §14 asks for "AirportService navigation data presented rather than new
	physics" and this function is where that promise is kept or broken.
]]
function Tablet.planFor(snapshot: Snapshot?, selection: Selection): any?
	if not snapshot or not selection.from or not selection.to then
		return nil
	end
	local byTo = snapshot.plans[selection.from :: string]
	return if byTo then byTo[selection.to :: string] else nil
end

-- =========================================================================
-- PRESENTATION - pure
-- =========================================================================

--[[
	A distance, in the two units that are both worth having.

	Nautical miles because that is what a pilot plans in and what the
	instruments imply; kilometres beside it because these legs are short enough
	that the nautical figure alone reads as a rounding error - Meadow to Ridge is
	0.87 nm, which looks like nothing until you see 1.6 km.
]]
function Tablet.distanceText(metres: number): string
	return string.format("%.2f nm  (%.2f km)", Units.metersToNauticalMiles(metres), metres / 1000)
end

--[[
	A bearing, three digits, as a runway designator is and as a pilot says it.

	360 rather than 000 for north, matching AirportService.headingOf and the
	runway numbering - "zero zero zero" is not a heading anybody flies.
]]
function Tablet.bearingText(degrees: number): string
	local rounded = math.floor(degrees + 0.5)
	if rounded <= 0 then
		rounded += 360
	elseif rounded > 360 then
		rounded -= 360
	end
	return string.format("%03d T", rounded)
end

--[[
	The summary block, as ordered label/value pairs.

	Returned as DATA rather than written straight into TextLabels, exactly as
	DebugHud.coreRows is, and for the same reason: the tests can then read what
	the pilot would read, which is the only way to catch a unit conversion that
	is silently the wrong way round.

	With no plan it returns a single explanatory row rather than an empty table,
	because a blank block on a panel reads as broken rather than as unset.
]]
function Tablet.summaryRows(snapshot: Snapshot?, selection: Selection): { { label: string, value: string } }
	local plan = Tablet.planFor(snapshot, selection)

	if not plan then
		return { { label = "ROUTE", value = "pick a departure and a destination" } }
	end

	return {
		{
			label = "ROUTE",
			value = string.format("%s %s  ->  %s %s", plan.fromName, plan.departureRunway, plan.toName, plan.arrivalRunway),
		},
		{ label = "DISTANCE", value = Tablet.distanceText(plan.distance) },
		{
			label = "BEARING",
			value = string.format("%s   (back %s)", Tablet.bearingText(plan.bearing), Tablet.bearingText(plan.reciprocal)),
		},
		{
			-- Signed, because a negative climb is a descent and the sign is the
			-- whole information. Ridge is 150 m above Meadow; the way home is
			-- -150 and reads as such.
			label = "CLIMB",
			value = string.format("%+.0f m   (field %.0f m -> %.0f m)", plan.climb, plan.departureElevation, plan.arrivalElevation),
		},
		{
			label = "CRUISE",
			value = string.format("%.0f m  (%.0f ft)", plan.cruiseAltitude, Units.metersToFeet(plan.cruiseAltitude)),
		},
	}
end

--[[
	One line under an airport's name in the picker.

	Elevation and surface, because those are the two things that change how the
	field is flown - a 400 m grass strip is a different arrival from a 250 m
	paved runway - and both are already in the snapshot.
]]
function Tablet.airportSubtitle(airport: any): string
	return string.format("%.0f m  %s  rwy %s", airport.elevation, airport.surface, table.concat(airport.runways, "/"))
end

--[[
	Why the tablet cannot be opened, in the pilot's words.

	One sentence, and it names the two ways out rather than only stating the
	refusal - a message that says "no" without saying "land, or engage altitude
	hold" would leave the pilot pressing M harder.
]]
Tablet.CLOSED_IN_FLIGHT_MESSAGE =
	"The cursor is the yoke while you are hand-flying. Land, or engage altitude hold (R), to use the tablet."

-- =========================================================================
-- BUILDING
-- =========================================================================

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3, textSize: number): TextLabel
	local element = Instance.new("TextLabel")
	element.BackgroundTransparency = 1
	element.Size = size
	element.Position = position
	element.Font = FONT
	element.Text = text
	element.TextColor3 = color
	element.TextSize = textSize
	element.TextXAlignment = Enum.TextXAlignment.Left
	element.TextYAlignment = Enum.TextYAlignment.Center
	element.Parent = parent
	return element
end

--[[
	One selectable row in a picker.

	A TextButton, which is the only class of thing in this project allowed to
	absorb a click, and it is allowed here only because the whole panel is gated
	(see the header). `AutoButtonColor` is off because the picked row's colour is
	state the pilot reads, and Roblox's hover tint would fight it.
]]
local function pickerRow(parent: Instance, index: number, title: string, subtitle: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Row" .. index
	button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT * 2)
	button.Position = UDim2.new(0, 0, 0, (index - 1) * (ROW_HEIGHT * 2 + 6))
	button.BackgroundColor3 = COLOR_ROW
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = button

	label(button, title, UDim2.new(1, -12, 0, ROW_HEIGHT), UDim2.new(0, 8, 0, 2), COLOR_TEXT, 15)
	label(button, subtitle, UDim2.new(1, -12, 0, ROW_HEIGHT - 6), UDim2.new(0, 8, 0, ROW_HEIGHT - 2), COLOR_DIM, 12)

	return button
end

--[[
	One picker column: a heading and a list of rows.

	Returns the column frame and its list frame, so render() can rebuild the rows
	without rebuilding the heading every time the snapshot arrives.
]]
local function pickerColumn(parent: Instance, name: string, heading: string, x: number, width: number): (Frame, Frame)
	local column = Instance.new("Frame")
	column.Name = name
	column.BackgroundTransparency = 1
	column.Size = UDim2.new(0, width, 1, -(HEADER_HEIGHT + SUMMARY_HEIGHT + PADDING * 2))
	column.Position = UDim2.new(0, x, 0, HEADER_HEIGHT + PADDING)
	column.Parent = parent

	label(column, heading, UDim2.new(1, 0, 0, ROW_HEIGHT), UDim2.new(0, 0, 0, 0), COLOR_HEADER, 13)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 1, -ROW_HEIGHT)
	list.Position = UDim2.new(0, 0, 0, ROW_HEIGHT)
	list.Parent = column

	return column, list
end

--[[
	The panel, into any parent.

	Knows nothing about a screen - §19's rule, kept here so the tablet can be
	mounted on a real cockpit slate during the 3D pass without touching this
	file. Returns a handle of the instances render() writes to, rather than
	making render() search the tree by name every frame.
]]
function Tablet.buildPanel(parent: Instance): any
	local panel = Instance.new("Frame")
	panel.Name = "TabletPanel"
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BorderSizePixel = 0
	panel.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, PADDING)
	padding.PaddingBottom = UDim.new(0, PADDING)
	padding.PaddingLeft = UDim.new(0, PADDING)
	padding.PaddingRight = UDim.new(0, PADDING)
	padding.Parent = panel

	label(panel, "FLIGHT TABLET", UDim2.new(0.5, 0, 0, ROW_HEIGHT), UDim2.new(0, 0, 0, 0), COLOR_HEADER, 18)

	local closeHint = label(
		panel,
		"M to close",
		UDim2.new(0.5, 0, 0, ROW_HEIGHT),
		UDim2.new(0.5, 0, 0, 0),
		COLOR_DIM,
		13
	)
	closeHint.TextXAlignment = Enum.TextXAlignment.Right

	local usable = PANEL_WIDTH - PADDING * 2
	local columnWidth = math.floor((usable - COLUMN_GAP * 2) / 3)

	local _, departureList = pickerColumn(panel, "Departure", "DEPARTURE", 0, columnWidth)
	local _, destinationList = pickerColumn(panel, "Destination", "DESTINATION", columnWidth + COLUMN_GAP, columnWidth)
	local _, aircraftList = pickerColumn(panel, "Aircraft", "AIRCRAFT", (columnWidth + COLUMN_GAP) * 2, columnWidth)

	-- ---- The summary block ------------------------------------------------
	local summary = Instance.new("Frame")
	summary.Name = "Summary"
	summary.Size = UDim2.new(1, 0, 0, SUMMARY_HEIGHT)
	summary.Position = UDim2.new(0, 0, 1, -SUMMARY_HEIGHT)
	summary.BackgroundColor3 = COLOR_BACKDROP
	summary.BorderSizePixel = 0
	summary.Parent = panel

	local summaryCorner = Instance.new("UICorner")
	summaryCorner.CornerRadius = UDim.new(0, 6)
	summaryCorner.Parent = summary

	--[[
		Five rows, built once and rewritten in place. Rebuilding them on every
		selection would churn instances for a panel whose SHAPE never changes -
		only its numbers do.
	]]
	local summaryRows = {}
	for i = 1, 5 do
		local y = 6 + (i - 1) * 20
		local rowLabel = label(summary, "", UDim2.new(0, 90, 0, 18), UDim2.new(0, 10, 0, y), COLOR_DIM, 13)
		local rowValue = label(summary, "", UDim2.new(1, -108, 0, 18), UDim2.new(0, 100, 0, y), COLOR_TEXT, 13)
		table.insert(summaryRows, { label = rowLabel, value = rowValue })
	end

	local start = Instance.new("TextButton")
	start.Name = "StartFlight"
	start.Size = UDim2.new(0, 180, 0, 26)
	start.Position = UDim2.new(1, -190, 1, -32)
	start.BackgroundColor3 = COLOR_GO
	start.BorderSizePixel = 0
	start.AutoButtonColor = false
	start.Font = FONT
	start.Text = "START FLIGHT"
	start.TextColor3 = COLOR_TEXT
	start.TextSize = 14
	start.Parent = summary

	local startCorner = Instance.new("UICorner")
	startCorner.CornerRadius = UDim.new(0, 4)
	startCorner.Parent = start

	local status = label(summary, "", UDim2.new(1, -210, 0, 20), UDim2.new(0, 10, 1, -30), COLOR_DIM, 12)

	return {
		panel = panel,
		lists = { from = departureList, to = destinationList, aircraftId = aircraftList },
		summaryRows = summaryRows,
		start = start,
		status = status,
	}
end

--[[
	The screen wrapper. Throwaway, exactly as SixPack.build() is.

	Built DISABLED. That is the safety property from the header expressed as one
	line: a ScreenGui that is not enabled contains no live GuiButton, so a closed
	tablet cannot absorb a single pixel of the yoke's travel.
]]
function Tablet.build(parent: Instance): (ScreenGui, any)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FlightTablet"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 20
	screenGui.Enabled = false
	screenGui.Parent = parent

	local handle = Tablet.buildPanel(screenGui)
	return screenGui, handle
end

-- =========================================================================
-- RENDERING
-- =========================================================================

local function clearList(list: Frame)
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

--[[
	Draw the pickers.

	Called when the snapshot arrives, not on every selection - the rows
	themselves do not change, only which of them is highlighted. `onPick` is
	handed the field and the id, so this function knows nothing about what
	choosing means; Tablet.choose owns that.
]]
function Tablet.renderPickers(handle: any, snapshot: Snapshot?, onPick: (string, string) -> ())
	local entries: { [string]: { any } } = {
		from = {},
		to = {},
		aircraftId = {},
	}

	if snapshot then
		for _, airport in snapshot.airports do
			local row = { id = airport.id, title = airport.name, subtitle = Tablet.airportSubtitle(airport) }
			table.insert(entries.from, row)
			table.insert(entries.to, row)
		end
	end

	for _, aircraft in Tablet.aircraftList() do
		table.insert(entries.aircraftId, { id = aircraft.id, title = aircraft.name, subtitle = aircraft.id })
	end

	handle.rows = {}

	--[[
		The handler is kept beside the button it is connected to.

		Not bookkeeping for its own sake: an RBXScriptSignal cannot be fired from
		a test, so the only way to assert that row 2 of the destination column
		really means "ridge" - the mapping bug that would look completely normal
		on screen - is to hold the exact closure that was connected and call it.
		This is the same shape as the pure/impure split everywhere else here: the
		decision is reachable without the instance.
	]]
	handle.handlers = {}

	for field, list in handle.lists do
		clearList(list)
		handle.rows[field] = {}
		handle.handlers[field] = {}

		for index, entry in entries[field] do
			local button = pickerRow(list, index, entry.title, entry.subtitle)
			local handler = function()
				onPick(field, entry.id)
			end

			handle.rows[field][entry.id] = button
			handle.handlers[field][entry.id] = handler
			button.Activated:Connect(handler)
		end
	end
end

--[[
	Draw the current selection: the highlight and the summary.

	Cheap on purpose - it runs on every click - and it writes only text and
	colour, never instances.
]]
function Tablet.renderSelection(handle: any, snapshot: Snapshot?, selection: Selection)
	if handle.rows then
		for field, buttons in handle.rows do
			local picked = (selection :: any)[field]
			for id, button in buttons do
				button.BackgroundColor3 = if id == picked then COLOR_ROW_PICKED else COLOR_ROW
			end
		end
	end

	local rows = Tablet.summaryRows(snapshot, selection)
	for i, row in handle.summaryRows do
		local source = rows[i]
		row.label.Text = if source then source.label else ""
		row.value.Text = if source then source.value else ""
	end

	--[[
		The start button is only live when there is something to start. A button
		that accepts a click and then reports "departure and destination are the
		same field" is a worse experience than one that is visibly unavailable.
	]]
	local flyable = Tablet.planFor(snapshot, selection) ~= nil
	handle.start.BackgroundColor3 = if flyable then COLOR_GO else COLOR_ROW
	handle.start.TextColor3 = if flyable then COLOR_TEXT else COLOR_DIM
end

function Tablet.setStatus(handle: any, text: string, warning: boolean?)
	handle.status.Text = text
	handle.status.TextColor3 = if warning then COLOR_WARN else COLOR_DIM
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.UI.Tablet.Tablet).runTests()

	Everything below drives the pure half - the selection rules and the exact
	strings a pilot reads - plus one pass that builds the real panel, because
	§17's lesson is that arithmetic tests cannot verify a rendering and the least
	this suite can do is prove the instances exist and absorb nothing when shut.
]]
function Tablet.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-54s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== Tablet: verification ===")

	--[[
		A synthetic snapshot in exactly the shape AirportService.tabletSnapshot()
		produces. Synthetic rather than fetched, because this suite runs on the
		client where that module does not exist - which is the same boundary the
		snapshot was invented to cross.

		THE NUMBERS ARE MEADOW AND RIDGE'S REAL ONES, read back off a live
		RequestAirportList rather than typed from the geometry - and that is not
		pedantry, it caught something. The obvious guess for the departure runway
		is Meadow's default, 36. The live answer is 18: bestRunwayFor() picks the
		runway pointing most nearly at the destination, and Ridge is 200 m SOUTH
		as well as 1,600 m east, so the leg departs southbound. A fixture written
		from the guess would have passed while disagreeing with the aeroplane the
		pilot was actually given.
	]]
	local snapshot: Snapshot = {
		airports = {
			{ id = "meadow", name = "Meadow Field", elevation = 250, surface = "paved", position = Vector3.new(0, 250, 0), runways = { "18", "36" }, defaultRunway = "36" },
			{ id = "ridge", name = "Ridge Strip", elevation = 400, surface = "grass", position = Vector3.new(1600, 400, 200), runways = { "09", "27" }, defaultRunway = "09" },
		},
		plans = {
			meadow = {
				ridge = {
					from = "meadow", to = "ridge",
					fromName = "Meadow Field", toName = "Ridge Strip",
					distance = 1612.45, bearing = 97.125, reciprocal = 277.125,
					departureElevation = 250, arrivalElevation = 400,
					climb = 150, cruiseAltitude = 705,
					departureRunway = "18", arrivalRunway = "09",
				},
			},
			ridge = {
				meadow = {
					from = "ridge", to = "meadow",
					fromName = "Ridge Strip", toName = "Meadow Field",
					distance = 1612.45, bearing = 277.125, reciprocal = 97.125,
					departureElevation = 400, arrivalElevation = 250,
					climb = -150, cruiseAltitude = 705,
					departureRunway = "27", arrivalRunway = "36",
				},
			},
		},
	}

	-- 1. The aircraft picker -------------------------------------------------
	local aircraft = Tablet.aircraftList()
	record(
		"The aircraft picker reads the registry",
		#aircraft == #Registry.ids() and aircraft[1].id == Registry.ids()[1],
		string.format("%d type(s): %s", #aircraft, aircraft[1] and aircraft[1].name or "none")
	)
	record(
		"...and the 172 is one of them, by name",
		aircraft[1] ~= nil and aircraft[1].id == "c172" and aircraft[1].name:find("172") ~= nil,
		aircraft[1] and aircraft[1].name or "none"
	)

	-- 2. The default selection ------------------------------------------------
	local atRidge = Tablet.defaultSelection(snapshot, "ridge")
	record(
		"Departure defaults to the field the pilot is at",
		atRidge.from == "ridge",
		tostring(atRidge.from)
	)
	record(
		"...and the destination is somewhere else",
		atRidge.to == "meadow",
		tostring(atRidge.to)
	)
	record(
		"...with the default aircraft already picked",
		atRidge.aircraftId == Registry.DEFAULT_ID,
		atRidge.aircraftId
	)

	--[[
		An unknown nearest field must not be trusted through. It arrives from a
		lookup that can legitimately fail - no character, no aircraft - and a
		departure the snapshot has never heard of would produce a tablet with no
		plan and no way to tell why.
	]]
	local unknown = Tablet.defaultSelection(snapshot, "heathrow")
	record(
		"An unknown nearest field falls back to a real one",
		unknown.from == "meadow" and unknown.to == "ridge",
		string.format("%s -> %s", tostring(unknown.from), tostring(unknown.to))
	)

	--[[
		The nearest-field helper the default above is fed from. Ridge is 1,600 m
		east and 200 m south of Meadow, so a point just east of Meadow is still
		Meadow's, and one at Ridge's own origin is Ridge's.
	]]
	record(
		"The nearest field is the nearest field",
		Tablet.nearestAirport(snapshot, Vector3.new(100, 250, 0)) == "meadow"
			and Tablet.nearestAirport(snapshot, Vector3.new(1600, 400, 200)) == "ridge",
		"meadow near the origin, ridge at its own"
	)
	--[[
		Horizontal only: 1,000 m directly above Meadow is at Meadow. Measuring in
		three dimensions would hand an aeroplane in the cruise to whichever field
		it happened to be closest to in a straight line, which is not a field it
		is anywhere near.
	]]
	record(
		"...measured horizontally, so altitude does not move it",
		Tablet.nearestAirport(snapshot, Vector3.new(0, 1250, 0)) == "meadow",
		"1,000 m above Meadow is still Meadow"
	)
	record(
		"With nothing to compare against it answers nil",
		Tablet.nearestAirport(nil, Vector3.zero) == nil and Tablet.nearestAirport(snapshot, nil) == nil,
		"nil rather than a guess"
	)

	local empty = Tablet.defaultSelection(nil, "meadow")
	record(
		"With no snapshot yet, nothing is selected and nothing errors",
		empty.from == nil and empty.to == nil and empty.aircraftId == Registry.DEFAULT_ID,
		"from and to both nil"
	)

	-- 3. Choosing ------------------------------------------------------------
	local selection = Tablet.defaultSelection(snapshot, "meadow")
	local swapped = Tablet.choose(selection, "from", "ridge")
	record(
		"Picking the destination as the departure SWAPS them",
		swapped.from == "ridge" and swapped.to == "meadow",
		string.format("%s -> %s", tostring(swapped.from), tostring(swapped.to))
	)
	--[[
		The same rule from the other side. Both directions are asserted because
		a swap written once and copied is exactly where a from/to mix-up hides,
		and the symptom - a leg planned backwards - looks entirely plausible.
	]]
	local swappedBack = Tablet.choose(selection, "to", "meadow")
	record(
		"...and picking the departure as the destination does too",
		swappedBack.from == "ridge" and swappedBack.to == "meadow",
		string.format("%s -> %s", tostring(swappedBack.from), tostring(swappedBack.to))
	)

	record(
		"Choosing leaves the original selection untouched",
		selection.from == "meadow" and selection.to == "ridge",
		"the caller's table is not mutated"
	)

	local reAircraft = Tablet.choose(selection, "aircraftId", "c172")
	record(
		"Choosing an aircraft leaves the route alone",
		reAircraft.from == "meadow" and reAircraft.to == "ridge" and reAircraft.aircraftId == "c172",
		"route unchanged"
	)

	-- 4. The plan is a lookup, not a calculation ------------------------------
	local plan = Tablet.planFor(snapshot, selection)
	record(
		"A selection resolves to the server's own plan",
		plan ~= nil and plan.distance == 1612.45 and plan.bearing == 97.125,
		plan and string.format("%.2f m on %.3f", plan.distance, plan.bearing) or "nil"
	)
	record(
		"A field to itself has no plan",
		Tablet.planFor(snapshot, { from = "meadow", to = "meadow", aircraftId = "c172" }) == nil,
		"nil, as flightPlan() returns"
	)
	record(
		"An incomplete selection has no plan",
		Tablet.planFor(snapshot, { from = "meadow", to = nil, aircraftId = "c172" }) == nil,
		"nil"
	)

	-- 5. What the pilot actually reads ----------------------------------------
	local rows = Tablet.summaryRows(snapshot, selection)
	local byLabel: { [string]: string } = {}
	for _, row in rows do
		byLabel[row.label] = row.value
	end

	--[[
		Both fields and both runways, and note the 18: the leg departs Meadow
		SOUTHBOUND because Ridge is south of east. See the fixture's own note -
		this is the value the live server returns, not the field's default.
	]]
	record(
		"The summary names both fields and both runways",
		byLabel.ROUTE == "Meadow Field 18  ->  Ridge Strip 09",
		byLabel.ROUTE or "missing"
	)

	--[[
		THE UNIT CHECK, and the reason the rows are data. 1,612.45 m is 0.87 nm
		and 1.61 km. A conversion inverted anywhere in this file gives 2,986 nm
		or 0.0016 km, and both would still render as a perfectly tidy panel.
	]]
	record(
		"Distance reads in nautical miles and kilometres",
		byLabel.DISTANCE == "0.87 nm  (1.61 km)",
		byLabel.DISTANCE or "missing"
	)
	record(
		"Bearing reads as three digits, with the way home beside it",
		byLabel.BEARING == "097 T   (back 277 T)",
		byLabel.BEARING or "missing"
	)
	record(
		"Climb is signed, so a descent reads as one",
		byLabel.CLIMB == "+150 m   (field 250 m -> 400 m)",
		byLabel.CLIMB or "missing"
	)

	--[[
		The return leg, which is where a sign error would show. Same fields, same
		distance, and every direction reversed.
	]]
	local homeRows = Tablet.summaryRows(snapshot, { from = "ridge", to = "meadow", aircraftId = "c172" })
	local home: { [string]: string } = {}
	for _, row in homeRows do
		home[row.label] = row.value
	end
	record(
		"The return leg descends and flies the reciprocal",
		home.CLIMB == "-150 m   (field 400 m -> 250 m)" and home.BEARING == "277 T   (back 097 T)",
		string.format("%s / %s", home.CLIMB or "?", home.BEARING or "?")
	)

	record(
		"With no plan the summary explains itself rather than going blank",
		#Tablet.summaryRows(snapshot, { from = nil, to = nil, aircraftId = "c172" }) == 1,
		Tablet.summaryRows(snapshot, { from = nil, to = nil, aircraftId = "c172" })[1].value
	)

	--[[
		North is 360, not 000, matching AirportService.headingOf and the way
		runways are numbered. Asserted at both ends of the wrap because
		rounding 359.6 upward is exactly how 000 appears on a panel.
	]]
	record(
		"North reads as 360, not 000",
		Tablet.bearingText(360) == "360 T" and Tablet.bearingText(359.6) == "360 T" and Tablet.bearingText(0.4) == "360 T",
		string.format("%s / %s / %s", Tablet.bearingText(360), Tablet.bearingText(359.6), Tablet.bearingText(0.4))
	)

	record(
		"An airport's subtitle carries elevation, surface and runways",
		Tablet.airportSubtitle(snapshot.airports[2]) == "400 m  grass  rwy 09/27",
		Tablet.airportSubtitle(snapshot.airports[2])
	)

	-- 6. The real panel --------------------------------------------------------
	--[[
		Built for real, because §17's lesson is that no amount of arithmetic
		verifies a rendering. This cannot prove the panel LOOKS right - only a
		screenshot does that - but it can prove the instances exist, that the
		pickers drew a row per airport, and the one property that is a safety
		rule rather than a nicety: a closed tablet absorbs nothing.
	]]
	local harness = Instance.new("Folder")
	harness.Name = "__TabletTestHarness"
	harness.Parent = game:GetService("ReplicatedStorage")

	local ok, err = pcall(function()
		local screenGui, handle = Tablet.build(harness)

		record(
			"A freshly built tablet is DISABLED, so it eats no clicks",
			screenGui.Enabled == false,
			"the cursor is still the yoke until the controller says otherwise"
		)

		local picks = {}
		Tablet.renderPickers(handle, snapshot, function(field, id)
			table.insert(picks, field .. "=" .. id)
		end)

		local fromRows, aircraftRows = 0, 0
		for _ in handle.rows.from do
			fromRows += 1
		end
		for _ in handle.rows.aircraftId do
			aircraftRows += 1
		end
		record(
			"The pickers drew a row per airport and per aircraft",
			fromRows == #snapshot.airports and aircraftRows == #Registry.ids(),
			string.format("%d airport rows, %d aircraft rows", fromRows, aircraftRows)
		)

		--[[
			Clicking a row must report which picker and which id - the mapping
			that would be silently wrong if the columns were built from a shared
			table and one of them kept a stale reference. Driven through the
			handler that is actually connected to the button; see the note in
			renderPickers for why it cannot be driven through the signal.
		]]
		handle.handlers.to.meadow()
		handle.handlers.aircraftId.c172()
		record(
			"Clicking a row reports which picker and which id",
			#picks == 2 and picks[1] == "to=meadow" and picks[2] == "aircraftId=c172",
			table.concat(picks, ", ")
		)

		Tablet.renderSelection(handle, snapshot, selection)
		record(
			"The picked row is highlighted and the others are not",
			handle.rows.from.meadow.BackgroundColor3 == COLOR_ROW_PICKED
				and handle.rows.from.ridge.BackgroundColor3 == COLOR_ROW,
			"meadow lit, ridge not"
		)
		record(
			"The summary block shows the selection",
			handle.summaryRows[2].value.Text == "0.87 nm  (1.61 km)",
			handle.summaryRows[2].value.Text
		)

		--[[
			And the start button goes dim when there is nothing to start. A
			live-looking button that refuses the click is worse than a dim one.
		]]
		Tablet.renderSelection(handle, snapshot, { from = "meadow", to = "meadow", aircraftId = "c172" })
		record(
			"START FLIGHT dims when the route is not flyable",
			handle.start.BackgroundColor3 == COLOR_ROW,
			"dimmed"
		)
		Tablet.renderSelection(handle, snapshot, selection)
		record(
			"...and lights again when it is",
			handle.start.BackgroundColor3 == COLOR_GO,
			"live"
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

return Tablet
