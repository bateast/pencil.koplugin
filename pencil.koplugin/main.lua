--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
-- Some Android file managers flatten the plugin folder on extraction; accept
-- geometry.lua next to main.lua as well as in lib/.
local ok_geom, PencilGeometry = pcall(require, "lib/geometry")
if not ok_geom then
    PencilGeometry = require("geometry")
end
-- Pure tool-set logic (presets, validation, box placement). Small, loaded up
-- front; the tool box widget itself is loaded the first time it is opened.
local ok_toolset, Toolset = pcall(require, "lib/toolset")
if not ok_toolset then
    Toolset = require("toolset")
end
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"
local HIGHLIGHTER_OPACITIES = { 20, 35, 50, 65, 80, 100 }
local DEFAULT_HIGHLIGHTER_OPACITY = 65
local DEFAULT_HIGHLIGHTER_COLOR_NAME = "Gray"

local function opacityToAlpha(percent)
    return math.floor(percent * 255 / 100 + 0.5)
end

local function alphaToOpacity(alpha)
    local percent = math.floor((alpha or 0xFF) * 100 / 255 + 0.5)
    local best, distance = HIGHLIGHTER_OPACITIES[1], math.huge
    for _, allowed in ipairs(HIGHLIGHTER_OPACITIES) do
        local d = math.abs(allowed - percent)
        if d < distance then best, distance = allowed, d end
    end
    return best
end

local function trimString(v) return tostring(v or ""):match("^%s*(.-)%s*$") end

-- Native PDF ink-annotation support (issue #63).
--
-- We call koreader-base's MuPDF wrapper directly, so this feature patches NO
-- core KOReader files. Everything we need comes from require("ffi/mupdf"):
-- koreader-base exports the ink setters as of koreader/koreader-base#2444,
-- shipped in KOReader 2026.07.
--
-- InkAnnot is nil when the symbols are absent, so on older KOReader builds the
-- feature degrades gracefully instead of erroring.
local InkAnnot = (function()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    -- Loads mupdf_h.lua, which on 2026.07+ declares the ink setters
    -- (koreader/koreader-base#2444); the probe below fails on older builds.
    if not pcall(require, "ffi/mupdf") then return nil end
    local W_ok, W = pcall(ffi.loadlib, "wrap-mupdf")
    if not W_ok or not W then return nil end
    -- Probe: the symbol resolves lazily and errors if the lib lacks it.
    if not pcall(function() return W.mupdf_pdf_set_annot_ink_list end) then return nil end
    local ink_ok, ink_type = pcall(function() return ffi.C.PDF_ANNOT_INK end)
    return { ffi = ffi, W = W, PDF_ANNOT_INK = ink_ok and ink_type or 15 }
end)()

-- Human-readable tool name for toasts and menus.
local function toolDisplayName(tool)
    if tool == TOOL_ERASER then
        return _("eraser")
    elseif tool == TOOL_HIGHLIGHTER then
        return _("highlighter")
    end
    return _("pencil")
end

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 500  -- How long pen must be held still (milliseconds)
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

-- Underline by holding the pen at the end of a horizontal stroke
local UNDERLINE_HOLD_MS = 600          -- How long the pen must rest at the end
local UNDERLINE_STILL_PIXELS = 10      -- Movement allowed while resting
local UNDERLINE_MIN_LENGTH = 40        -- Shorter strokes are never underlines
local UNDERLINE_MAX_SLOPE = 0.25       -- Max stroke height / width
local UNDERLINE_SEARCH_PIXELS = 48     -- How far above the stroke to look for text

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 4       -- seconds after last stroke before capturing
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge
local STROKES_PATH_SETTING = "pencil_strokes_path"
-- Format of pencil_strokes.lua this version writes. A file with a higher
-- version came from a newer Pencil; it's left untouched (see loadStrokes).
local STROKES_FILE_VERSION = 5
local ANNOTATION_HOLD_HIT_PAD = 18  -- extra pixels around annotation bbox

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil
local _bookmark_hook_installed = false

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)
    eraser_button_active = false,  -- Hardware eraser button held
    eraser_button_deleted = {},    -- Track deletions for undo
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    highlighting = false,

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh
    -- Screen-space bbox of strokes drawn since the last delayed refresh fired.
    -- The post-lift "clean" refresh is scoped to this region instead of the
    -- whole screen, so a dense page doesn't trigger a full-panel e-ink update.
    pending_refresh_bbox = nil,

    -- Debounced save - coalesces full O(N) serialization across consecutive strokes.
    -- Force-flushed on page change, close, and the deferred-work scheduler.
    pending_save = nil,
    save_delay_ms = 1500,
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,
            color = nil,  -- Set in init (needs Blitbuffer)
            color_name = DEFAULT_HIGHLIGHTER_COLOR_NAME,
            alpha = opacityToAlpha(DEFAULT_HIGHLIGHTER_OPACITY),
        },
        [TOOL_ERASER] = {
            width = 20,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_contact = nil,
    eraser_role_active = false,
    eraser_role_from_button = false,
    eraser_contact = nil,
    highlight_freehand = false,

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed
    color_picker_tool = nil,

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    -- Technique borrowed from eraser.koplugin by SimonLiu <simonliu423@gmail.com>
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.strokes_loaded = false  -- Set true after successful loadStrokes
    self.undo_stack = {}

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Available colors for color picker (Blitbuffer color values)
    self.available_colors = {
        { name = "Black", color = Blitbuffer.COLOR_BLACK },
        { name = "Red", color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = Blitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = Blitbuffer.Color8(gray_value) },
    }

    -- The tool box offers the marker the same colors as the highlighter menu
    -- and hold picker: the main palette without black.
    self.highlight_colors = self:getHighlighterColors()

    -- Available pen widths for the optional experimental width picker.
    -- Gated by self.experimental_pen_width; see loadSettings().
    self.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("Pencil: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("Pencil: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isEnabled() then
        self:setupPenInput()
    end

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("Pencil: toggle pencil/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("Pencil: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("Pencil: select pencil"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("Pencil: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_highlighter", {
        category = "none",
        event = "PencilSelectHighlighter",
        title = _("Pencil: select highlighter"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_swap_tool", {
        category = "none",
        event = "PencilSwapTool",
        title = _("Pencil: swap to previous tool"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_open_toolbox", {
        category = "none",
        event = "PencilOpenToolBox",
        title = _("Pencil: open tool box"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("Pencil: undo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    logger.info("Pencil: initialized, enabled =", self:isEnabled(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    self:togglePenEraser(true)
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isEnabled()
    self:setEnabled(not enabled)
    self:closeToolBox()
    if self:isEnabled() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil disabled"),
            timeout = 1,
        })
    end
    return true
end

function Pencil:onPencilSelectPen()
    self:switchTool({ tool = TOOL_PEN })
    self:showToast(_("Pencil tool: pencil"), true)
    return true
end

function Pencil:onPencilSelectEraser()
    self:switchTool({ tool = TOOL_ERASER })
    self:showToast(_("Eraser selected"), true)
    return true
end

function Pencil:onPencilSelectHighlighter()
    self:switchTool({ tool = TOOL_HIGHLIGHTER })
    self:showToast(_("Tool: highlighter"), true)
    return true
end

-- Flip between the tool in hand and the one before it (pen <-> marker, a red
-- pen <-> a black pen, ...): one gesture, no menu.
function Pencil:onPencilSwapTool()
    if not self.prev_tool_state then
        self:showToast(_("No previous tool yet"), true)
        return true
    end
    local new, prev = Toolset.swap(self:getToolState(), self.prev_tool_state)
    self:applyToolState(new)
    self.prev_tool_state = prev
    self:saveSettings()
    self:showToast(T(_("Tool: %1"), toolDisplayName(self.current_tool)), true)
    return true
end

function Pencil:onPencilOpenToolBox()
    if not self:isEnabled() then
        self:showToast(_("Enable Pencil first"), true)
        return true
    end
    self:showToolBox()
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    logger.info("Pencil: stylus callback registered")
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function Pencil:transformCoordinates(x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
--
-- Tracks whether the current contact belongs to the plugin: it does once
-- we've handled one of its samples, until it lifts. Every lift clears it,
-- whichever branch handled the lift, so a stale flag like pen_down can't
-- keep the plugin from handing later contacts to an overlay.
function Pencil:handleStylusSlot(input, slot)
    local handled = self:routeStylusSlot(input, slot)
    if slot.id and slot.id >= 0 then
        if handled then self.owns_contact = true end
    else
        self.owns_contact = false
    end
    return handled
end

local ERASER_CLICK_TOLERANCE = 10

-- A physical side-button click always toggles the selected pen/eraser tool.
-- Swap Eraser/Highlighter only exchanges the roles used while dragging.
function Pencil:beginSideButtonContact()
    self.side_button_down = true
    self.side_button_contact = { dragging = false, x0 = nil, y0 = nil }
end

function Pencil:trackSideButtonContact(x, y)
    local contact = self.side_button_contact
    if not contact or contact.dragging or x == nil or y == nil then return end
    if contact.x0 == nil then
        contact.x0, contact.y0 = x, y
        return
    end
    local dx, dy = x - contact.x0, y - contact.y0
    if dx * dx + dy * dy > ERASER_CLICK_TOLERANCE * ERASER_CLICK_TOLERANCE then
        contact.dragging = true
    end
end

function Pencil:finishSideButtonContact()
    local contact = self.side_button_contact
    local clicked = contact ~= nil and not contact.dragging
    self.side_button_down = false
    self.side_button_contact = nil
    return clicked
end

function Pencil:activateEraserRole(from_button)
    if self.eraser_role_active then return false end
    self.eraser_role_active = true
    self.eraser_role_from_button = from_button == true
    self.eraser_contact = nil
    self.eraser_button_deleted = {}
    return true
end

function Pencil:finishEraserRole(button_click)
    if not self.eraser_role_active then return false end
    local contact = self.eraser_contact
    local clicked = (contact and not contact.dragging)
        or (not contact and button_click and self.eraser_role_from_button)
    if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
        self:commitErase(self.eraser_button_deleted)
    end
    self.eraser_role_active = false
    self.eraser_role_from_button = false
    self.eraser_contact = nil
    self.eraser_button_deleted = nil
    UIManager:setDirty(self.view, "ui")
    return clicked
end

function Pencil:trackEraserContact(active, x, y)
    local contact = self.eraser_contact
    if active then
        if not contact then
            self.eraser_contact = { x0 = x, y0 = y, dragging = false }
            return "hold"
        end
        if not contact.dragging then
            local dx, dy = x - contact.x0, y - contact.y0
            if dx * dx + dy * dy > ERASER_CLICK_TOLERANCE * ERASER_CLICK_TOLERANCE then
                contact.dragging = true
                return "drag_start"
            end
            return "hold"
        end
        return "drag"
    elseif contact then
        self.eraser_contact = nil
        return contact.dragging and "end" or "click"
    end
    return nil
end

function Pencil:eraseWithEraserRole(x, y, overlay)
    if overlay then return end
    local deleted = self:eraseAtPoint(x, y, self:getCurrentPage())
    if deleted then
        self.eraser_button_deleted = self.eraser_button_deleted or {}
        for _, stroke in ipairs(deleted) do
            self.eraser_button_deleted[#self.eraser_button_deleted + 1] = stroke
        end
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
        if rx then Screen:refreshFast(rx, ry, rw, rh)
        else Screen:refreshFast(0, 0, Screen:getWidth(), Screen:getHeight()) end
    end
    self:eraseHighlightAtScreenPos(x, y)
    self.pen_x, self.pen_y = x, y
end

function Pencil:isEraserRoleTool(slot_tool)
    return (not self.swap_eraser_and_highlighter and slot_tool == 2)
        or (self.swap_eraser_and_highlighter and slot_tool == 3)
end

function Pencil:isHighlighterRoleTool(slot_tool)
    return (not self.swap_eraser_and_highlighter
            and (self.side_button_down or slot_tool == 3))
        or (self.swap_eraser_and_highlighter and slot_tool == 2)
end

function Pencil:routeStylusSlot(input, slot)
    if self.input_debug_mode then
        self:writeDebugLog(string.format(
            "STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_role=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.eraser_role_active)))
    end

    local overlay = self:isOverlayActive()
    if overlay and not self.owns_contact then return false end
    local touching = slot.id and slot.id >= 0
    if touching and self.side_button_down then
        local bx, by = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
        self:trackSideButtonContact(bx, by)
    end

    -- The eraser role is the physical eraser end normally and the side button
    -- when swapped. A stationary contact is a click; deletion starts only after
    -- movement exceeds the tolerance.
    local eraser_tool = self:isEraserRoleTool(slot.tool)
    if eraser_tool and not self.eraser_role_active then
        self:activateEraserRole(false)
    elseif self.eraser_role_active and not self.eraser_role_from_button and not eraser_tool then
        local clicked = self:finishEraserRole(false)
        if clicked and self:isEnabled() then self:togglePenEraser() end
    end

    if self.eraser_role_active then
        local x, y
        if touching then
            x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
        end
        local phase = self:trackEraserContact(touching, x, y)
        if phase == "drag_start" then
            local contact = self.eraser_contact
            self:eraseWithEraserRole(contact.x0, contact.y0, overlay)
            self:eraseWithEraserRole(x, y, overlay)
        elseif phase == "drag" then
            self:eraseWithEraserRole(x, y, overlay)
        elseif phase == "click" and self:isEnabled() then
            self:togglePenEraser()
        end
        return true
    end

    -- A contact starting while the picker is visible belongs to the picker.
    if self.color_picker_showing and self.color_picker_widget and touching and not self.pen_down then
        local px, py = self:transformCoordinates(slot.x or 0, slot.y or 0)
        if self.color_picker_widget:handlePenTap(px, py) then return true end
    end

    -- The highlighter role is the side button normally and the eraser end when
    -- swapped. Text-vs-freehand is decided once, at contact start.
    local highlighter_role = self:isHighlighterRoleTool(slot.tool)
    if self.experimental_text_highlight
            and (highlighter_role or self.highlighting or self.highlight_freehand) then
        if touching and self.highlighting then
            self:extendTextHighlight(slot.x or 0, slot.y or 0)
            local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
            self.pen_x, self.pen_y = hx, hy
            self:movePickerTracking(hx, hy)
            return true
        elseif not touching and self.highlighting then
            self:cancelColorPickerTimer()
            self:finishTextHighlight()
            return true
        elseif touching and highlighter_role and not self.pen_down and not self.highlight_freehand then
            -- Starting a text highlight consumes this side-button press as
            -- a modifier action. Mark the contact as dragging immediately
            -- so releasing the button before the pen moves/lifts cannot
            -- be mistaken for a click and toggle the selected tool.
            local contact = self.side_button_contact
            if contact then
                contact.dragging = true
            end
            if self:startTextHighlight(slot.x or 0, slot.y or 0) then
                local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
                self.pen_x, self.pen_y = hx, hy
                self:beginPickerTracking(hx, hy, TOOL_HIGHLIGHTER)
                return true
            end
            self.highlight_freehand = true
        elseif not touching and self.highlight_freehand then
            self.highlight_freehand = false
            -- Continue to the normal lift path to finish the freehand stroke.
        end
    end

    if not self:isEnabled() then return false end

    local effective_tool
    if highlighter_role or self.highlight_freehand then
        effective_tool = TOOL_HIGHLIGHTER
    else
        effective_tool = self.current_tool
    end

    -- The selected eraser on the pen tip retains ordinary immediate erasing.
    if effective_tool == TOOL_ERASER then
        if touching then
            local first_touch = not self.pen_down
            if first_touch then
                self.pen_down, self.erasing, self.eraser_deleted = true, true, {}
            end
            local x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local deleted = not overlay and self:eraseAtPoint(x, y, self:getCurrentPage())
                if deleted then
                    for _, stroke in ipairs(deleted) do self.eraser_deleted[#self.eraser_deleted + 1] = stroke end
                    self.view:paintTo(Screen.bb, 0, 0)
                    self:paintTo(Screen.bb, 0, 0)
                    local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
                    if rx then Screen:refreshUI(rx, ry, rw, rh)
                    else Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight()) end
                end
                self.pen_x, self.pen_y = x, y
            end
        elseif self.pen_down and self.erasing then
            self.pen_down, self.erasing = false, false
            if self.eraser_deleted and #self.eraser_deleted > 0 then self:commitErase(self.eraser_deleted) end
            self.eraser_deleted = nil
            UIManager:setDirty(self.view, "ui")
        end
        return true
    end

    if touching then
        if not self.pen_down then
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:cancelUnderlineHold()
            self:startRawStroke(effective_tool)
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            self.pen_x = x
            self.pen_y = y
            self:beginPickerTracking(x, y, effective_tool)
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            local x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                self:movePickerTracking(x, y)
                if not overlay then
                    self:addRawPoint(x, y)
                    self:trackUnderlineHold(x, y)
                end
                self.pen_x, self.pen_y = x, y
            end
        end
    elseif self.pen_down and not self.erasing then
        self.pen_down = false
        self:cancelColorPickerTimer()
        self:cancelUnderlineHold()
        self:endRawStroke()
        self.highlight_freehand = false
        if self.input_debug_mode then self:writeDebugLog("=== PEN UP ===") end
    end
    return true
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self.stylus_callback_registered = false
    self.pen_down = false
    self.side_button_down = false
    self.side_button_contact = nil
    logger.info("Pencil: stylus callback unregistered")
end

-- Start a new stroke from raw input
function Pencil:startRawStroke(tool)
    local page = self:getCurrentPage()
    tool = tool or (self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool)
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]


    self.current_stroke = {
        page = page,
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and self.current_stroke.color_name ~= "Black" and self.current_stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        -- Draw first point same size as line segments for consistency
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawLiveHighlighter(self.current_stroke, x, y, x, y)
        else
            local half_w_draw = math.floor(width / 2)
            Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        end
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawLiveHighlighter(self.current_stroke, p1.x, p1.y, p2.x, p2.y)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            -- Expand existing dirty region
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        if self.dirty_region then
            local r = self.dirty_region
            -- Clamp to screen bounds
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            -- Use UI refresh mode for proper color rendering on color e-ink
            Screen:refreshUI(rx, ry, rw, rh)
            self.dirty_region = nil
        end
    end
end

-- Refresh the screen area drawn since the last refresh, if any.
function Pencil:refreshDirtyRegion()
    local r = self.dirty_region
    if not r then return end
    -- Clamp to screen bounds
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if self.stroke_fast_refresh then
        -- Fast monochrome waveform: lowest e-ink latency for dark ink
        Screen:refreshFast(rx, ry, rw, rh)
    else
        -- UI waveform: needed for proper shading of light/colored ink
        Screen:refreshUI(rx, ry, rw, rh)
    end
    self.dirty_region = nil
end

-- Restart the underline hold timer whenever the pen moves beyond the
-- "still" tolerance; leave it running while the pen rests.
function Pencil:trackUnderlineHold(x, y)
    if not self.underline_hold or self.side_button_down then return end
    if self.underline_still_x
            and math.abs(x - self.underline_still_x) <= UNDERLINE_STILL_PIXELS
            and math.abs(y - self.underline_still_y) <= UNDERLINE_STILL_PIXELS then
        return
    end
    self.underline_still_x = x
    self.underline_still_y = y
    if not self._underline_check then
        -- One closure per plugin instance, reused for every reschedule.
        self._underline_check = function() self:checkUnderlineHold() end
    end
    UIManager:unschedule(self._underline_check)
    UIManager:scheduleIn(UNDERLINE_HOLD_MS / 1000, self._underline_check)
end

function Pencil:cancelUnderlineHold()
    self.underline_still_x = nil
    self.underline_still_y = nil
    if self._underline_check then
        UIManager:unschedule(self._underline_check)
    end
end

-- Fired after the pen rested UNDERLINE_HOLD_MS: if the stroke so far is a
-- roughly horizontal line under text, turn it into a native underline.
function Pencil:checkUnderlineHold()
    local stroke = self.current_stroke
    if not (self.pen_down and stroke and not self.highlighting) then return end
    if stroke.tool ~= TOOL_PEN or #stroke.points < 2 then return end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    local w, h = bbox.x1 - bbox.x0, bbox.y1 - bbox.y0
    if w < UNDERLINE_MIN_LENGTH or h > w * UNDERLINE_MAX_SLOPE then return end
    if not self:underlineTextAbove(bbox) then return end

    -- The ink was only a gesture: drop it and repaint where it was.
    self.current_stroke = nil
    self.dirty_region = nil
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local pad = (stroke.width or 3) + 4
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rx, ry = math.max(0, bbox.x0 - pad), math.max(0, bbox.y0 - pad)
    Screen:refreshUI(rx, ry, math.min(sw - rx, w + 2 * pad), math.min(sh - ry, h + 2 * pad))
end

-- Find the page position of the text just above a screen point, looking
-- up to UNDERLINE_SEARCH_PIXELS. Returns the page position and the offset.
function Pencil:findTextAbove(x, y)
    for dy = 2, UNDERLINE_SEARCH_PIXELS, 4 do
        local page_pos = self.ui.view:screenToPageTransform({ x = x, y = y - dy })
        if page_pos then
            local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
            if ok and word and word.pos0 then
                return page_pos, dy
            end
        end
    end
end

-- Save a native KOReader underline over the text above a stroke bbox.
-- @return true if a highlight was saved
function Pencil:underlineTextAbove(bbox)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return false
    end
    local start_pos, dy = self:findTextAbove(bbox.x0 + 2, bbox.y0)
    if not start_pos then return false end
    -- Use the same text line for the end point.
    local end_pos = self.ui.view:screenToPageTransform({ x = bbox.x1 - 2, y = bbox.y0 - dy })
    if not end_pos then return false end

    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, start_pos, end_pos)
    if not (ok and selected and selected.pos0 and selected.pos1) then return false end
    selected.drawer = "underscore"

    local rh = self.ui.highlight
    rh.selected_text = selected
    local saved, err = pcall(rh.saveHighlight, rh, false)
    if not saved then
        logger.warn("Pencil: saving underline failed:", tostring(err))
    end
    if rh.clear then pcall(rh.clear, rh) end
    return saved
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        self:commitStroke(self.current_stroke)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
        -- Track the region this stroke touched so the delayed refresh below
        -- can be scoped to it instead of the whole screen.
        self:accumulateRefreshBbox(self.current_stroke)
        -- Schedule delayed refresh for clean display after writing stops.
        -- Not when nothing was saved, e.g. a hold that opened the color
        -- picker: a fast refresh over it would grey out its swatches.
        self:scheduleDelayedRefresh()
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    self.current_stroke = nil
    self.live_highlighter = nil
end

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when slot.tool has been promoted to HIGHLIGHTER
-- by input.lua (i.e., the side button is held during a pen contact).
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return false
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return false end
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if not (ok and word and word.pos0 and word.pos1) then return false end
    local rh = self.ui.highlight
    rh.hold_pos = page_pos
    rh.selected_text = {
        text = word.word or "", pos0 = word.pos0, pos1 = word.pos1,
        sboxes = word.sbox and { word.sbox } or {},
        pboxes = word.pbox and { word.pbox } or {},
    }
    rh.selected_text_start_xpointer = word.pos0
    rh.allow_hold_pan_corner_scroll = false
    rh.was_in_some_corner = nil
    self.highlighting = true
    self.pen_down = true
    self:_paintTempSelection()
    return true
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)

    -- Let ReaderHighlight extend the selection as it does for a finger
    -- long-press drag. In EPUBs, that scrolls on to the next page when the
    -- pen goes into the bottom right corner (back at the top left), so a
    -- highlight can cross pages. Lifting undoes the scroll (rh:clear() in
    -- finishTextHighlight). It returns false when long-press is set to "Do
    -- nothing"; we still highlight then, within the page.
    local ok_pan, handled = pcall(rh.onHoldPan, rh, nil,
        { pos = Geom:new{ x = screen_x, y = screen_y, w = 0, h = 0 } })
    if not ok_pan then
        logger.warn("Pencil: onHoldPan failed:", tostring(handled))
    elseif handled ~= false then
        self:_paintTempSelection()
        return
    end

    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        rh.selected_text = selected
        -- Repaint preview with the new sboxes.
        self:_paintTempSelection()
    end
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    -- Stop the long-hold timer onHoldPan starts; we don't show its menu.
    if rh and rh._resetHoldTimer then
        pcall(rh._resetHoldTimer, rh, true)
    end
    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    for index, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page_pos.page then
                    local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                          self.ui.document, page_pos.page, item.pos0, item.pos1)
                    if ok then boxes = got end
                end
            else
                -- Rolling mode (EPUB): work in screen coordinates directly.
                local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                      self.ui.document, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes then
                local px = is_paging and page_pos.x or screen_x
                local py = is_paging and page_pos.y or screen_y
                for _, box in ipairs(boxes) do
                    if px >= box.x and px < box.x + box.w
                            and py >= box.y and py < box.y + box.h then
                        return index
                    end
                end
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    -- Use ReaderHighlight:deleteHighlight, not bookmark:removeItemByIndex.
    -- The latter only drops the highlight from KOReader's list; the former also
    -- removes it from the PDF (via writePdfAnnotation "delete") when write-into-
    -- PDF is on -- otherwise MuPDF keeps rendering the baked annotation and the
    -- highlight never disappears. The PDF mutation is in-memory; our close
    -- flush writes it out (mark dirty so it does).
    if not (self.ui and self.ui.highlight and self.ui.highlight.deleteHighlight) then
        return false
    end
    local item = self.ui.annotation.annotations[index]
    local ok = pcall(self.ui.highlight.deleteHighlight, self.ui.highlight, index)
    if ok then
        self._pdf_dirty = true
        -- KOReader only deletes the PDF copy when "write highlights into PDF"
        -- is on, but "Save annotations to PDF (this page)" can put it in the
        -- file with that setting off. Remove whatever copy is still there.
        local dok, derr = pcall(self.deleteHighlightFromPdf, self, item)
        if not dok then logger.warn("Pencil: deleting highlight from PDF failed:", derr) end
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/pencil_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== Pencil Annotation Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("Pencil: cleared debug log at", log_path)
    end
end

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Experimental features
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    -- Swap eraser and highlighter
    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    self.experimental_pen_width = settings.experimental_pen_width or false
    self.experimental_color_picker = settings.experimental_color_picker or false
    self.experimental_text_highlight = settings.experimental_text_highlight or false
    -- MyScript handwriting recognition settings.
    self.myscript_language = settings.myscript_language or "en_US"
    self.myscript_application_key = settings.myscript_application_key or ""
    self.myscript_hmac_key = settings.myscript_hmac_key or ""

    -- Auto-save pencil ink into the PDF file when the document is closed.
    self.auto_save_pdf = settings.auto_save_pdf or false
    self.underline_hold = settings.underline_hold ~= false
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
    -- Load highlighter color and opacity, validating both against the UI lists.
    -- An unknown name (a hand-edited file) falls back to the default instead of
    -- leaving the highlighter without a color.
    local function pickHighlighterColor(name)
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == name and color_info.name ~= "Black" then
                self.tool_settings[TOOL_HIGHLIGHTER].color_name = color_info.name
                self.tool_settings[TOOL_HIGHLIGHTER].color = color_info.color
                return true
            end
        end
        return false
    end
    if not pickHighlighterColor(settings.highlighter_color_name or DEFAULT_HIGHLIGHTER_COLOR_NAME) then
        pickHighlighterColor(DEFAULT_HIGHLIGHTER_COLOR_NAME)
    end
    local saved_opacity = settings.highlighter_opacity or DEFAULT_HIGHLIGHTER_OPACITY
    for _, allowed in ipairs(HIGHLIGHTER_OPACITIES) do
        if allowed == saved_opacity then
            self.tool_settings[TOOL_HIGHLIGHTER].alpha = opacityToAlpha(allowed)
            break
        end
    end
    -- Load pen width if previously chosen via the experimental width picker.
    -- Validated against available_widths so a malformed settings file can't
    -- inject arbitrary widths.
    -- Whole pixels within sane bounds, so a malformed settings file can't
    -- inject an arbitrary width. (Saved presets can use widths outside the
    -- picker's four, so this is a range check, not a list lookup.)
    local saved_width = settings.pen_width
    if Toolset.isValidWidth(saved_width) then
        self.tool_settings[TOOL_PEN].width = saved_width
    end

    -- Quick tool box
    self.valid_color_names = {}
    for _, info in ipairs(self.available_colors) do self.valid_color_names[info.name] = true end
    for _, info in ipairs(self.highlight_colors) do self.valid_color_names[info.name] = true end
    self.tool_box_hold = settings.tool_box_hold or false
    -- Early tool box builds named the marker's default gray "Highlight".
    if type(settings.tool_presets) == "table" then
        for _, preset in ipairs(settings.tool_presets) do
            if type(preset) == "table" and preset.color_name == "Highlight" then
                preset.color_name = "Gray"
            end
        end
    end
    self.tool_presets = Toolset.normalize(settings.tool_presets, self.valid_color_names)
    if Toolset.isValidWidth(settings.highlighter_width) then
        self.tool_settings[TOOL_HIGHLIGHTER].width = settings.highlighter_width
    end
    if Toolset.isValidWidth(settings.eraser_width) then
        self.tool_settings[TOOL_ERASER].width = settings.eraser_width
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    G_reader_settings:saveSetting("pencil_annotation_settings", {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        experimental_pen_width = self.experimental_pen_width,
        experimental_color_picker = self.experimental_color_picker,
        experimental_text_highlight = self.experimental_text_highlight,
        myscript_language = self.myscript_language,
        myscript_application_key = self.myscript_application_key,
        myscript_hmac_key = self.myscript_hmac_key,
        auto_save_pdf = self.auto_save_pdf,
        underline_hold = self.underline_hold,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        pen_width = self.tool_settings[TOOL_PEN].width,
        tool_box_hold = self.tool_box_hold,
        tool_presets = self.tool_presets,
        highlighter_color_name = self.tool_settings[TOOL_HIGHLIGHTER].color_name,
        highlighter_opacity = alphaToOpacity(self.tool_settings[TOOL_HIGHLIGHTER].alpha),
        highlighter_width = self.tool_settings[TOOL_HIGHLIGHTER].width,
        eraser_width = self.tool_settings[TOOL_ERASER].width,
    })
end

-- Set current tool
function Pencil:setTool(tool)
    self:switchTool({ tool = tool })
    -- Show visual feedback with proper display name
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), toolDisplayName(tool)),
        timeout = 1,
    })
end

function Pencil:isEnabled()
    return G_reader_settings:readSetting("pencil_annotation_enabled") == true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- Like getTopmostVisibleWidget, skip widgets marked invisible (transient
    -- decorations that paint but don't capture input, e.g. TrapWidget). Also
    -- skip toasts, which KOReader passes input through, like our own
    -- confirmations (see showToast).
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if not widget.invisible and not widget.toast then
            return (widget.name or widget.id) ~= "ReaderUI"
        end
    end
    return false
end

-- Show a short confirmation (tool, color, width) as a KOReader notification:
-- a small banner at the top of the screen, out of the writing area. It's a
-- toast, which KOReader passes input through and isOverlayActive skips, so a
-- stroke started while one is showing is drawn in full. Gesture actions pass
-- from_gesture so they follow the reader's notification settings, like other
-- gestures do; the side button and color picker always show theirs.
function Pencil:showToast(text, from_gesture)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, from_gesture and Notification.SOURCE_DISPATCHER
        or Notification.SOURCE_ALWAYS_SHOW)
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

function Pencil:getHighlighterColors()
    local colors = {}
    for _, info in ipairs(self.available_colors) do
        if info.name ~= "Black" then colors[#colors + 1] = info end
    end
    return colors
end

function Pencil:setHighlighterColor(color, color_name)
    if not color or not color_name or color_name == "Black" then return false end
    local hl = self.tool_settings[TOOL_HIGHLIGHTER]
    hl.color, hl.color_name = color, color_name
    self:saveSettings()
    return true
end

function Pencil:setHighlighterOpacity(percent)
    for _, allowed in ipairs(HIGHLIGHTER_OPACITIES) do
        if percent == allowed then
            self.tool_settings[TOOL_HIGHLIGHTER].alpha = opacityToAlpha(percent)
            self:saveSettings()
            return true
        end
    end
    return false
end

function Pencil:buildHighlighterMenu()
    local color_items = {}
    for _, info in ipairs(self:getHighlighterColors()) do
        color_items[#color_items + 1] = {
            text = info.name, radio = true, keep_menu_open = true,
            checked_func = function() return self.tool_settings[TOOL_HIGHLIGHTER].color_name == info.name end,
            callback = function() self:setHighlighterColor(info.color, info.name) end,
        }
    end
    local opacity_items = {}
    for _, percent in ipairs(HIGHLIGHTER_OPACITIES) do
        opacity_items[#opacity_items + 1] = {
            text = string.format("%d%%", percent), radio = true, keep_menu_open = true,
            checked_func = function() return alphaToOpacity(self.tool_settings[TOOL_HIGHLIGHTER].alpha) == percent end,
            callback = function() self:setHighlighterOpacity(percent) end,
        }
    end
    return {
        text_func = function()
            local hl = self.tool_settings[TOOL_HIGHLIGHTER]
            return T(_("Highlighter: %1, %2"), hl.color_name or "?",
                string.format("%d%%", alphaToOpacity(hl.alpha)))
        end,
        sub_item_table = {
            { text = _("Color"), sub_item_table = color_items },
            { text = _("Opacity"), sub_item_table = opacity_items },
        },
    }
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
                separator = true,
            },
            {
                text = _("Swap Eraser and Highlighter"),
                checked_func = function()
                    return self.swap_eraser_and_highlighter
                end,
                callback = function()
                    self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
                    self:saveSettings()
                end,
                separator = true,
            },
            self:buildHighlighterMenu(),
            {
                text = _("Tool"),
                help_text = _("Select pencil, highlighter or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Highlighter"),
                        checked_func = function()
                            return self.current_tool == TOOL_HIGHLIGHTER
                        end,
                        callback = function()
                            self:setTool(TOOL_HIGHLIGHTER)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Tool box"),
                help_text = _("A small panel to switch tool, preset, color, width and eraser size without leaving the page."),
                sub_item_table = {
                    {
                        text = _("Open tool box"),
                        callback = function()
                            -- after the menu has closed, so it isn't painted over
                            UIManager:scheduleIn(0.2, function() self:onPencilOpenToolBox() end)
                        end,
                        enabled_func = function()
                            return self:isEnabled()
                        end,
                    },
                    {
                        text = _("Open by holding the pen still"),
                        help_text = _("Hold the pen still on the page for half a second to open the tool box. Takes the place of the experimental color picker. Off by default, so pausing while you write doesn't open it."),
                        checked_func = function()
                            return self.tool_box_hold
                        end,
                        callback = function()
                            self.tool_box_hold = not self.tool_box_hold
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Reset saved tools"),
                        help_text = _("Put the preset row back to the default pens and markers."),
                        callback = function()
                            self.tool_presets = Toolset.normalize(nil, self.valid_color_names)
                            self:saveSettings()
                        end,
                    },
                },
            },
            {
                text = _("Undo last stroke"),
                callback = function()
                    self:undoLastStroke()
                end,
                enabled_func = function()
                    return #self.undo_stack > 0
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self:hasStrokesOnCurrentPage()
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return #self.strokes > 0
                end,
            },
            {
                text_func = function()
                    local bytes = self:getImagesSizeBytes()
                    if bytes <= 0 then
                        return _("Annotation images: none")
                    elseif bytes < 1024 * 1024 then
                        return T(_("Annotation images: %1 KB"), math.floor(bytes / 1024))
                    else
                        return T(_("Annotation images: %1 MB"),
                            string.format("%.1f", bytes / (1024 * 1024)))
                    end
                end,
                help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getImagesSizeBytes() > 0
                end,
                callback = function(touchmenu_instance)
                    self:purgeAllImages()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Cleared all annotation preview images for this book."),
                        timeout = 2,
                    })
                end,
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for pencil annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                self:refreshDogear()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                self:refreshDogear()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. Pencil bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Color picker"),
                        help_text = _("Allow the hold-pen-still gesture to open a picker for changing pen color (and, if the pen width picker is also enabled, stroke width). When disabled, the pen stays on its last-saved color."),
                        checked_func = function()
                            return self.experimental_color_picker
                        end,
                        callback = function()
                            self.experimental_color_picker = not self.experimental_color_picker
                            self:saveSettings()
                            if self.experimental_color_picker then
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker enabled. Hold the pen still to open it."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker disabled. Pen will keep its current color."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Pen width picker"),
                        help_text = _("Add pen width options (3, 5, 7, 9) to the color picker. The width buttons appear as black bars whose height previews the stroke thickness. Requires the color picker to also be enabled."),
                        checked_func = function()
                            return self.experimental_pen_width
                        end,
                        callback = function()
                            self.experimental_pen_width = not self.experimental_pen_width
                            self:saveSettings()
                            if self.experimental_pen_width then
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker enabled. Hold the pen still to open the picker and choose a stroke width."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Underline by holding at line end"),
                        help_text = _("Draw a line under text and rest the pen at the end for a moment: the ink is replaced by a native KOReader underline on the words above it."),
                        checked_func = function()
                            return self.underline_hold
                        end,
                        callback = function()
                            self.underline_hold = not self.underline_hold
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Text highlight (side button)"),
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the underlying words, like a long-press \xe2\x86\x92 Highlight. Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.experimental_text_highlight
                        end,
                        callback = function()
                            self.experimental_text_highlight = not self.experimental_text_highlight
                            self:saveSettings()
                            if self.experimental_text_highlight then
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight enabled. Hold the side button while dragging the pen across words."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Save annotations to PDF (this page)"),
                        help_text = _("Add this page's pencil strokes (as ink annotations) and text highlights (as native highlight annotations) to the PDF, so they travel with the file and are visible in any PDF reader. The file is written when you close the book. Highlights already in the PDF are skipped. PDF documents only; requires KOReader 2026.07 or newer."),
                        keep_menu_open = true,
                        -- Always selectable for PDFs (it reports if there's
                        -- nothing on the page), so it's never hidden/greyed.
                        enabled_func = function()
                            return self:isPdfDocument()
                        end,
                        callback = function()
                            self:saveCurrentPageToPdf()
                        end,
                    },
                    {
                        text = _("Auto-save pencil ink to PDF on close"),
                        help_text = _("When enabled, every pencil stroke you've drawn is written into the PDF file as a native ink annotation when you close the document, so your annotations travel with the file. Runs once per session (only new strokes are added). PDF documents only; requires KOReader 2026.07 or newer. Text highlights are not auto-saved — use the per-page action above for those."),
                        enabled_func = function()
                            return self:isPdfDocument() and InkAnnot ~= nil
                        end,
                        checked_func = function()
                            return self.auto_save_pdf == true
                        end,
                        callback = function()
                            self.auto_save_pdf = not self.auto_save_pdf
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = self.auto_save_pdf
                                    and _("Pencil ink will be saved into the PDF when you close the document.")
                                    or _("Auto-save to PDF disabled."),
                                timeout = 2,
                            })
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Handwriting recognition"),
                sub_item_table = {
                    { text = _("Configure MyScript"), callback = function() self:showMyScriptSettingsDialog() end },
                    { text = _("Recognize latest annotation group"),
                      enabled_func = function() return self:getLatestAnnotationGroupOnCurrentPage() ~= nil end,
                      callback = function() local g = self:getLatestAnnotationGroupOnCurrentPage(); if g then self:recognizeAnnotationGroup(g) end end },
                    {
                        text = _("Recognize all annotation groups"),
                        enabled_func = function()
                            return self.annotation_groups and #self.annotation_groups > 0
                        end,
                        callback = function()
                            self:recognizeAllAnnotationGroups()
                        end,
                    },
                    {
                        text = _("Show all recognized text"),
                        enabled_func = function()
                            return self:hasRecognizedAnnotations()
                        end,
                        callback = function()
                            self:showAllRecognizedText()
                        end,
                    },
                    {
                        text = _("Edit all recognized text"),
                        enabled_func = function()
                            return self:hasRecognizedAnnotations()
                        end,
                        callback = function()
                            self:editAllRecognizedText()
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Input debug mode"),
                help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                checked_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self.input_debug_mode = not self.input_debug_mode
                    self:saveSettings()
                    if self.input_debug_mode then
                        -- Initialize debug logging
                        self:initDebugLog()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Input debug mode disabled."),
                        })
                    end
                end,
            },
            {
                text = _("Clear debug log"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self:clearDebugLog()
                    UIManager:show(InfoMessage:new{
                        text = _("Debug log cleared. Ready to capture new input events."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Show annotation status"),
                callback = function()
                    self:showAnnotationStatus()
                end,
            },
        },
    }
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = self.page_strokes[page] and #self.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[Pencil Annotation Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Eraser end: click to switch pen/eraser, drag to erase.
Side button: hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.current_tool,
        #self.strokes,
        page_strokes,
        tostring(page),
        type(page),
        filepath,
        self:isEnabled() and _("Yes") or _("No"),
        pages_info,
        stylus_callback_status,
        tostring(pen_slot),
        pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Highlighter-role button: highlights while held; it never toggles the tool.
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end
    self:beginSideButtonContact()
    logger.dbg("Pencil: side button pressed")
    return true
end

function Pencil:onStylusButtonRelease()
    if not self.side_button_down then return false end
    local clicked = self:finishSideButtonContact()
    if clicked and self:isEnabled() then self:togglePenEraser() end
    logger.dbg("Pencil: side button released, clicked =", clicked)
    return true
end

-- Toggle between pen and eraser
-- Coming back from the eraser returns to the drawing tool it was picked from
-- (pencil or highlighter), not always the pencil.
function Pencil:togglePenEraser(from_gesture)
    local old_tool = self.current_tool
    local new_tool
    if self.current_tool == TOOL_ERASER then
        new_tool = self.tool_before_eraser or TOOL_PEN
    else
        self.tool_before_eraser = self.current_tool
        new_tool = TOOL_ERASER
    end

    self:switchTool({ tool = new_tool })
    logger.dbg("Pencil: toggled from", old_tool, "to", new_tool)

    -- Show brief visual feedback
    self:showToast(T(_("Tool: %1"), toolDisplayName(new_tool)), from_gesture)
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    local ok_str, key_str = pcall(tostring, key)
    if not ok_str then key_str = "" end
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end
    local is_button = key.key == "Eraser"
        or key_str:match("Highlighter") or key_str:match("Stylus")
    local is_rubber = key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber")
    if is_rubber then
        self.eraser_tool_active = not self.swap_eraser_and_highlighter
        if not self.swap_eraser_and_highlighter then self:activateEraserRole(false) end
        return true
    elseif is_button then
        if self:isEnabled() and not self:isOverlayActive() then
            self:beginSideButtonContact()
            -- Defer swapped eraser-role activation until routeStylusSlot(),
            -- where slot.tool distinguishes the side button (3) from the
            -- physical eraser end (2). Some Kobo events label both as
            -- a generic "Eraser" key, so the key event alone is ambiguous.
            logger.dbg("Pencil: side button pressed")
            return true
        end
    end
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then return true end
    return false
end

function Pencil:onKeyRelease(key)
    local ok_str, key_str = pcall(tostring, key)
    if not ok_str then key_str = "" end
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end
    local is_button = key.key == "Eraser"
        or key_str:match("Highlighter") or key_str:match("Stylus")
    local is_rubber = key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber")
    if is_rubber then
        self.eraser_tool_active = false
        if not self.swap_eraser_and_highlighter then
            local clicked = self:finishEraserRole(false)
            if clicked and self:isEnabled() then self:togglePenEraser() end
        end
        return true
    elseif is_button then
        if self.side_button_down then
            if self.swap_eraser_and_highlighter and self.eraser_role_active
                    and self.eraser_role_from_button then
                self:finishEraserRole(false)
            end
            return self:onStylusButtonRelease()
        end
    end
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then return true end
    return false
end

-- Undo last stroke
function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    if last_action.type == "add" then
        -- Remove the stroke that was added
        local stroke_idx = last_action.stroke_idx
        if stroke_idx and self.strokes[stroke_idx] then
            -- Take its ink out of the PDF too, if it was saved there.
            self:deleteEmbeddedAnnotationsFor({ self.strokes[stroke_idx] })
            table.remove(self.strokes, stroke_idx)
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:flushDirtyGroups()
            self:refreshDogear()
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        end
    elseif last_action.type == "delete" then
        -- Restore deleted strokes
        for _, stroke in ipairs(last_action.strokes) do
            table.insert(self.strokes, stroke)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:flushDirtyGroups()
        self:refreshDogear()
        self:saveStrokes()
        UIManager:setDirty(self.view, "ui")
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self.ui:registerTouchZones({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
    })
    self.touch_zones_registered = false
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Annotation/badge interception has priority over ReaderHighlight.
    if ges and ges.pos then
        local group = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
            or self:findAnnotationGroupAtPoint(ges.pos.x, ges.pos.y)
        if group then
            self:showAnnotationHoldMenu(group)
            return true
        end
    end

    if self.pen_down then return true end
    local is_pen = select(1, self:isPenInput(ges))
    if not is_pen then return false end
    return true
end

-- Union a finished stroke's (screen-space) bounding box into the pending
-- post-lift refresh region, expanded by the stroke's own half-width plus a
-- small antialiasing pad. The delayed refresh then only updates this region.
function Pencil:accumulateRefreshBbox(stroke)
    if not stroke then return end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end
    local margin = math.floor((stroke.width or 0) / 2) + 4
    bbox = PencilGeometry.bboxExpand(bbox, margin)
    if self.pending_refresh_bbox then
        self.pending_refresh_bbox = PencilGeometry.bboxUnion(self.pending_refresh_bbox, bbox)
    else
        self.pending_refresh_bbox = bbox
    end
end

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- Schedule new refresh. Store the closure itself (not scheduleIn's nil
    -- return) so cancelPendingRefresh can actually unschedule it.
    local action
    action = function()
        if self.pending_refresh == action then self.pending_refresh = nil end
        local bbox = self.pending_refresh_bbox
        self.pending_refresh_bbox = nil
        if bbox then
            -- Scope the fast refresh to the region the recent strokes touched,
            -- so only that part of the panel updates. The strokes are already
            -- in the framebuffer; this only pushes them to the e-ink panel.
            bbox = PencilGeometry.bboxClampToScreen(bbox, Screen:getWidth(), Screen:getHeight())
            local rw = bbox.x1 - bbox.x0
            local rh = bbox.y1 - bbox.y0
            if rw > 0 and rh > 0 then
                local region = Geom:new{ x = bbox.x0, y = bbox.y0, w = rw, h = rh }
                UIManager:setDirty(self.view, "fast", region)
            else
                UIManager:setDirty(self.view, "fast")
            end
        else
            -- No tracked region (e.g. refresh scheduled without a finished
            -- stroke) — fall back to a full-view fast refresh.
            UIManager:setDirty(self.view, "fast")
        end
        logger.dbg("Pencil: delayed refresh triggered")
    end
    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Schedule a debounced save + bookmark flush after writing pauses.
-- NOTE: UIManager:scheduleIn() returns nil, and UIManager:unschedule() matches
-- by the action function reference. So we must store the closure itself in
-- pending_save (not scheduleIn's return value) or cancelPendingSave can never
-- cancel it — which previously caused one full save to fire per stroke.
function Pencil:scheduleDeferredWork()
    self:cancelPendingSave()
    local action
    action = function()
        if self.pending_save == action then self.pending_save = nil end
        self:flushDirtyGroups()
        -- New ink's bookmark is only added here, so fold the page corner now
        -- rather than on the next page turn.
        self:refreshDogear()
        self:saveStrokes()
    end
    self.pending_save = action
    UIManager:scheduleIn(self.save_delay_ms / 1000, action)
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    if not self.pending_save and not (self.dirty_groups and next(self.dirty_groups)) then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Recheck KOReader's dogear (the folded page corner) for the current page.
-- The plugin adds and removes its bookmarks directly in the annotation list,
-- and KOReader only rechecks the dogear on page turns, so without this the
-- corner stays down after the ink it marked is erased.
function Pencil:refreshDogear()
    local bookmark = self.ui and self.ui.bookmark
    local view = self.view
    if not (bookmark and bookmark.setDogearVisibility and bookmark.getCurrentPageNumber
            and view and view.dogear) then
        return
    end
    local was_visible = view.dogear_visible
    local ok, err = pcall(function()
        bookmark:setDogearVisibility(bookmark:getCurrentPageNumber())
    end)
    if not ok then
        logger.warn("Pencil: dogear refresh failed:", err)
        return
    end
    if view.dogear_visible ~= was_visible then
        -- Same refresh KOReader uses when toggling a bookmark by hand.
        UIManager:setDirty(view.dialog, function()
            return "ui", view.dogear:getRefreshRegion()
        end)
    end
end

-- Finish an eraser pass: record it for undo, re-add bookmarks for the ink
-- that survived (erasing rebuilds every group and drops their bookmarks),
-- update the dogear, and save.
function Pencil:commitErase(deleted)
    if not deleted or #deleted == 0 then return end
    table.insert(self.undo_stack, { type = "delete", strokes = deleted })
    -- Every eraser input path ends here, so this is where the strokes' baked
    -- PDF ink is removed: one page-tile refresh per gesture, not per hit.
    self:deleteEmbeddedAnnotationsFor(deleted)
    self:flushDirtyGroups()
    self:refreshDogear()
    self:saveStrokes()
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

function Pencil:isPickerEnabledFor(tool)
    -- Holding still opens the tool box for any drawing tool (not during a text
    -- highlight, whose picker is the highlighter's own).
    if self.tool_box_hold and not self.highlighting then return true end
    if tool == TOOL_HIGHLIGHTER then return self.experimental_color_picker end
    return self.experimental_color_picker or self.experimental_pen_width
end

function Pencil:beginPickerTracking(x, y, tool)
    if not self:isPickerEnabledFor(tool) then return end
    self.color_picker_tool = tool
    self.color_picker_start_x, self.color_picker_start_y = x, y
    self.color_picker_start_time = time.now()
    self:scheduleColorPickerCheck()
end

function Pencil:movePickerTracking(x, y)
    if not self.color_picker_start_x or not self.color_picker_start_y then return end
    if math.abs(x - self.color_picker_start_x) > COLOR_PICKER_TOLERANCE_PIXELS
            or math.abs(y - self.color_picker_start_y) > COLOR_PICKER_TOLERANCE_PIXELS then
        self:resetColorPickerTracking()
    end
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    local tool = self.color_picker_tool or TOOL_PEN
    if not self:isPickerEnabledFor(tool) or not self.color_picker_start_time
            or self.color_picker_showing then return end
    if time.to_ms(time.now() - self.color_picker_start_time) >= COLOR_PICKER_DELAY_MS then
        -- The tool box, when chosen as the hold-still action, takes the place of
        -- the color picker; a text highlight keeps the highlighter's own picker.
        if self.tool_box_hold and not self.highlighting then
            self:showToolBox(self.pen_x, self.pen_y)
        else
            self:showColorPicker(self.pen_x, self.pen_y, tool)
        end
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    -- Check every 100ms for trigger. Store the closure itself, not
    -- scheduleIn's nil return, so cancelColorPickerTimer can unschedule it
    -- (see scheduleDeferredWork).
    local action
    action = function()
        if plugin.color_picker_check_pending == action then
            plugin.color_picker_check_pending = nil
        end
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            -- Schedule next check if still waiting
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end
    self.color_picker_check_pending = action
    UIManager:scheduleIn(0.1, action)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- Color picker widget for selecting pen color (and optionally pen width).
-- When `widths` is provided, the widget shows two rows: colors on top,
-- widths below. The width row contains black bars whose vertical thickness
-- matches the actual stroke thickness in device pixels (what-you-see is
-- what-you-draw).
local ColorPickerWidget = InputContainer:extend {
    width = nil,
    height = nil,
    colors = nil, -- Array of {color, name} objects
    widths = nil, -- Optional array of {name, width} objects (experimental width picker)
    opacities = nil,
    opacity_color = nil,
    current_opacity = nil,
    current_color_name = nil, -- Currently selected color name (for comparison)
    current_width = nil, -- Currently selected pen width (for width selection indicator)
    callback = nil,
    close_callback = nil,
    -- Layout constants cached after init so handlePenTap / paintTo don't
    -- recompute them. Kept on self so tests can read them too.
    _button_size = nil,
    _spacing = nil,
    _row_gap = nil,
    _padding = nil,
}

-- Build one button (color or width). Returns the InputContainer button, which
-- also stores its own color / width metadata so the callback can route without
-- string-matching on name.
function ColorPickerWidget:_makeButton(item, button_size, selection_border)
    -- Selection: colors compare by name, widths compare by width value
    local is_selected
    if item.kind == "width" then
        is_selected = (item.width_value == self.current_width)
    elseif item.kind == "opacity" then
        is_selected = (item.opacity_value == self.current_opacity)
    else
        is_selected = (item.name == self.current_color_name)
    end
    local border_size = is_selected and selection_border or Size.border.thick

    local swatch
    if item.kind == "width" then
        -- Truthful preview: a horizontal black bar whose height equals the
        -- stroke's actual device-pixel thickness. We deliberately do NOT
        -- scale by Screen:scaleBySize — the stroke itself is drawn in raw
        -- pixels (see paintRectRGB32 in drawLineSegment), so scaling here
        -- would lie about the line weight.
        local inner = button_size - border_size * 2
        local bar_h = item.width_value
        local bar_w = math.floor(inner * 0.7)
        local bar = FrameContainer:new{
            width = bar_w,
            height = bar_h,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_BLACK,
            WidgetContainer:new{
                dimen = Geom:new{ w = bar_w, h = bar_h },
            },
        }
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = inner },
                bar,
            },
        }
    elseif item.kind == "opacity" then
        swatch = FrameContainer:new{
            width = button_size, height = button_size, padding = 0, margin = 0,
            bordersize = border_size, color = Blitbuffer.COLOR_BLACK,
            background = item.preview,
            WidgetContainer:new{ dimen = Geom:new{
                w = button_size - border_size * 2, h = button_size - border_size * 2 } },
        }
    else
        -- Regular color swatch
        local border_color = Blitbuffer.COLOR_BLACK
        if item.name == "Black" then
            border_color = Blitbuffer.Color8(0x44)
        end
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = border_color,
            background = item.color_value,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }
        if Screen.night_mode and item.name ~= "Black" and item.name ~= "Gray" then
            swatch.background = swatch.background:invert()
        end
    end

    local button = InputContainer:new{
        dimen = Geom:new{ w = button_size, h = button_size },
        swatch,
        kind = item.kind,
        color_value = item.color_value,  -- nil for width items
        color_name = item.name,
        width_value = item.width_value,  -- nil for color items
        opacity_value = item.opacity_value,
    }

    button.ges_events = {
        TapSelectColor = {
            GestureRange:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }

    local widget = self
    button.onTapSelectColor = function(btn)
        if widget.callback then
            widget.callback(btn.color_value, btn.color_name, btn.width_value, btn.opacity_value)
        end
        if widget.close_callback then
            widget.close_callback()
        end
        return true
    end

    return button
end

-- Build a HorizontalGroup row of buttons from an item list. Populates the
-- supplied `info_list` in-tap-index order.
function ColorPickerWidget:_buildRow(items, button_size, spacing, selection_border, info_list)
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = spacing })
        end
        local button = self:_makeButton(item, button_size, selection_border)
        table.insert(group, button)
        table.insert(info_list, button)
    end
    return group
end

function ColorPickerWidget:init()
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)  -- vertical gap between color row and width row
    local padding = Screen:scaleBySize(10)
    local selection_border = Size.border.thick * 3

    self._button_size = button_size
    self._spacing = spacing
    self._row_gap = row_gap
    self._padding = padding

    -- Build optional color row. `colors` is nil when the color-picker
    -- experimental flag is off; in that case we render a widths-only picker.
    local has_colors = self.colors and #self.colors > 0
    self.color_buttons_info = {}
    local color_row_group
    local colors_row_width = 0
    if has_colors then
        local color_items = {}
        for _, color_info in ipairs(self.colors) do
            table.insert(color_items, {
                kind = "color",
                name = color_info.name,
                color_value = color_info.color,
            })
        end
        color_row_group = self:_buildRow(color_items, button_size, spacing, selection_border, self.color_buttons_info)
        colors_row_width = #color_items * button_size + (#color_items - 1) * spacing
    end

    -- Build optional second row: pen widths or highlighter opacities.
    local has_opacities = self.opacities and #self.opacities > 0
    local has_widths = (self.widths and #self.widths > 0) or has_opacities
    self.width_buttons_info = {}
    local width_row_group
    local widths_row_width = 0
    if has_widths then
        local width_items = {}
        if has_opacities then
            local base = (self.opacity_color or Blitbuffer.Color8(0xCC)):getColorRGB32()
            for _, percent in ipairs(self.opacities) do
                local k = percent / 100
                table.insert(width_items, {
                    kind = "opacity", name = string.format("%d%%", percent),
                    opacity_value = percent,
                    preview = Blitbuffer.ColorRGB32(
                        math.floor(255 - (255 - base.r) * k + 0.5),
                        math.floor(255 - (255 - base.g) * k + 0.5),
                        math.floor(255 - (255 - base.b) * k + 0.5), 0xFF),
                })
            end
        else
            for _, width_info in ipairs(self.widths) do
                table.insert(width_items, {
                    kind = "width", name = width_info.name, width_value = width_info.width,
                })
            end
        end
        width_row_group = self:_buildRow(width_items, button_size, spacing, selection_border, self.width_buttons_info)
        widths_row_width = #width_items * button_size + (#width_items - 1) * spacing
    end

    -- Inner width accommodates the wider of the visible rows. Height
    -- accumulates one button_size per visible row plus a gap when both
    -- are showing.
    local visible_rows = (has_colors and 1 or 0) + (has_widths and 1 or 0)
    local inner_w = math.max(colors_row_width, widths_row_width)
    self.width = inner_w
    self.height = visible_rows * button_size + (visible_rows > 1 and row_gap or 0)

    local content
    if has_colors and has_widths then
        content = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = button_size },
                color_row_group,
            },
            VerticalSpan:new{ width = row_gap },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = button_size },
                width_row_group,
            },
        }
    elseif has_colors then
        content = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            color_row_group,
        }
    else
        -- widths-only picker (color picker experimental flag off)
        content = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            width_row_group,
        }
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        content,
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()

    -- Register gesture to close when tapping outside
    self.ges_events = {
        TapCloseOutside = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                } end,
            },
        },
    }
end

-- Hit-test one row of buttons. `row_y` is the top y of the row in absolute
-- coordinates. Returns the matching button info or nil.
function ColorPickerWidget:_hitRow(x, y, row_y, info_list)
    local button_size = self._button_size
    local spacing = self._spacing
    if #info_list == 0 then return nil end
    if y < row_y or y >= row_y + button_size then return nil end

    local row_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = self.dimen.x + (self.dimen.w - row_buttons_width) / 2
    local relative_x = x - row_start_x
    if relative_x < 0 or relative_x >= row_buttons_width then return nil end

    local stride = button_size + spacing
    local idx = math.floor(relative_x / stride) + 1
    local pos_in_slot = relative_x - (idx - 1) * stride
    if pos_in_slot >= button_size then return nil end
    if idx < 1 or idx > #info_list then return nil end
    return info_list[idx]
end

-- Handle pen/stylus tap on color picker
-- Returns true if the tap was handled (hit a button or was inside picker)
function ColorPickerWidget:handlePenTap(x, y)
    if not self.dimen then
        return false
    end

    -- Check if tap is inside the widget
    local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
            and y >= self.dimen.y and y < self.dimen.y + self.dimen.h

    if not inside then
        -- Tap outside - close the picker
        if self.close_callback then
            self.close_callback()
        end
        return true  -- Consume the event to prevent drawing
    end

    local border = Size.border.window
    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding

    -- When colors are hidden (color-picker flag off, width-picker on),
    -- the widths row slides up to the top-row position. The info-lists
    -- drive which row is where.
    local top_row_y = self.dimen.y + border + padding
    local colors_present = #self.color_buttons_info > 0
    local widths_row_y = colors_present and (top_row_y + button_size + row_gap) or top_row_y

    local btn = self:_hitRow(x, y, top_row_y, self.color_buttons_info)
        or self:_hitRow(x, y, widths_row_y, self.width_buttons_info)

    if btn then
        if self.callback then
            self.callback(btn.color_value, btn.color_name, btn.width_value, btn.opacity_value)
        end
        if self.close_callback then
            self.close_callback()
        end
        return true
    end

    -- Inside picker but didn't hit a button - still consume the event
    return true
end

-- Handle tap - close if outside the widget
function ColorPickerWidget:onTapCloseOutside(_, ges)
    if ges and ges.pos and self.dimen then
        -- Check if tap is inside the widget using coordinate comparison
        local x, y = ges.pos.x, ges.pos.y
        local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
                and y >= self.dimen.y and y < self.dimen.y + self.dimen.h
        if inside then
            -- Tap is inside, let the color buttons handle it
            return false
        end
    end
    -- Tap is outside, close the widget without changing color
    if self.close_callback then
        self.close_callback()
    end
    return true
end

-- Update button dimens for one row so individual TapSelectColor gesture ranges
-- match the painted positions. Mirrors the centered layout built in init().
function ColorPickerWidget:_placeRow(info_list, paint_x, frame_inner_width, padding, border, row_y)
    if #info_list == 0 then return end
    local button_size = self._button_size
    local spacing = self._spacing
    local total_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = paint_x + border + padding + (frame_inner_width - total_buttons_width) / 2
    for i, btn in ipairs(info_list) do
        btn.dimen.x = row_start_x + (i - 1) * (button_size + spacing)
        btn.dimen.y = row_y
    end
end

function ColorPickerWidget:paintTo(bb, x, y)
    -- Use absolute position from dimen if set, otherwise use passed coordinates
    local paint_x = self.dimen and self.dimen.x or x
    local paint_y = self.dimen and self.dimen.y or y

    -- Paint the frame at the absolute position
    self.frame:paintTo(bb, paint_x, paint_y)

    if not self.color_buttons_info then return end

    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding
    local border = Size.border.window
    local frame_inner_width = self.dimen.w - 2 * padding - 2 * border

    -- Symmetric with handlePenTap: widths slide up to the top slot when
    -- no colors are visible.
    local top_row_y = paint_y + border + padding
    local colors_present = #self.color_buttons_info > 0

    if colors_present then
        self:_placeRow(self.color_buttons_info, paint_x, frame_inner_width, padding, border, top_row_y)
    end

    if self.width_buttons_info and #self.width_buttons_info > 0 then
        local widths_row_y = colors_present and (top_row_y + button_size + row_gap) or top_row_y
        self:_placeRow(self.width_buttons_info, paint_x, frame_inner_width, padding, border, widths_row_y)
    end
end

function ColorPickerWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Show color picker popup near the pen position
function Pencil:showColorPicker(x, y, tool)
    if self.color_picker_showing then return end
    tool = tool or TOOL_PEN
    local highlighter = tool == TOOL_HIGHLIGHTER
    if highlighter and self.highlighting then
        self:_clearTempSelection()
        local rh = self.ui and self.ui.highlight
        if rh and rh.clear then pcall(rh.clear, rh) end
        self.highlighting = false
        self.highlight_freehand = true
    end
    -- Discard any current stroke that was made while holding still
    -- The user was holding still to trigger color picker, not intentionally drawing
    self:discardCurrentStroke()

    self.color_picker_showing = true
    local plugin = self
    local colors = highlighter and self:getHighlighterColors()
        or (self.experimental_color_picker and self.available_colors or nil)
    local widths = (not highlighter and self.experimental_pen_width) and self.available_widths or nil
    local opacities = highlighter and HIGHLIGHTER_OPACITIES or nil
    local n1 = colors and #colors or 0
    local n2 = opacities and #opacities or (widths and #widths or 0)
    local bs, spacing = Screen:scaleBySize(36), Screen:scaleBySize(8)
    local gap, padding, border = Screen:scaleBySize(8), Screen:scaleBySize(10), Size.border.window
    local function rowWidth(n) return n > 0 and n * bs + (n - 1) * spacing or 0 end
    local pw = math.max(rowWidth(n1), rowWidth(n2)) + padding * 2 + border * 2
    local rows = (n1 > 0 and 1 or 0) + (n2 > 0 and 1 or 0)
    local ph = rows * bs + padding * 2 + border * 2 + (rows > 1 and gap or 0)
    local margin, edge = Screen:scaleBySize(30), 10
    local px, py = x - pw / 2, y - ph - margin
    px = math.max(edge, math.min(px, Screen:getWidth() - pw - edge))
    if py < edge then py = y + margin end
    py = math.max(edge, math.min(py, Screen:getHeight() - ph - edge))
    local hl = self.tool_settings[TOOL_HIGHLIGHTER]
    local widget = ColorPickerWidget:new{
        colors = colors, widths = widths, opacities = opacities,
        opacity_color = hl.color, current_opacity = alphaToOpacity(hl.alpha),
        current_color_name = highlighter and hl.color_name
            or self.tool_settings[TOOL_PEN].color_name,
        current_width = self.tool_settings[TOOL_PEN].width,
        callback = function(color, name, width, opacity)
            if opacity then
                plugin:setHighlighterOpacity(opacity)
                plugin:showToast(T(_("Highlighter opacity: %1"), string.format("%d%%", opacity)))
            elseif highlighter then
                plugin:setHighlighterColor(color, name)
                plugin:showToast(T(_("Highlighter color: %1"), name))
            elseif width then
                plugin:setPenWidth(width)
                plugin:showToast(T(_("Pen width: %1"), width))
            else
                plugin:setPenColor(color, name)
                plugin:showToast(T(_("Pen color: %1"), name))
            end
        end,
        close_callback = function()
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            UIManager:setDirty(plugin.view, "ui")
        end,
    }
    widget.dimen = widget.dimen or Geom:new{}
    widget.dimen.x, widget.dimen.y = px, py
    self.color_picker_widget = widget
    UIManager:show(widget)
    UIManager:setDirty(widget, "ui")
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Set pen width. Only callable while experimental_pen_width is on
-- (the picker is the only UI path that invokes this).
function Pencil:setPenWidth(width)
    self.tool_settings[TOOL_PEN].width = width
    logger.info("Pencil: setPenWidth - width =", width)
    self:saveSettings()
end

------------------------------------------------------------------------------
-- Tools and the quick tool box (widget: lib/toolbox.lua)
--
-- Nothing in this section runs while the pen is drawing. The stylus callback
-- only reads tool_settings, exactly as before; the tool box is created when
-- asked for and freed when closed.
------------------------------------------------------------------------------

-- Color by name in the palette a tool uses ("Highlight" only exists for the
-- highlighter). Returns a Blitbuffer color or nil.
function Pencil:findColor(tool, name)
    local list = tool == TOOL_HIGHLIGHTER and self.highlight_colors or self.available_colors
    for _, info in ipairs(list) do
        if info.name == name then return info.color end
    end
    return nil
end

-- Color by name in either palette, for strokes loaded from disk.
function Pencil:findColorByName(name)
    return self:findColor(TOOL_PEN, name) or self:findColor(TOOL_HIGHLIGHTER, name)
end

-- The tool in hand as a plain table: { tool, color_name, width, eraser_width },
-- plus `opacity` (percent) for the highlighter. For the eraser, `width` is its size.
function Pencil:getToolState()
    local tool = self.current_tool
    local eraser_width = self.tool_settings[TOOL_ERASER].width
    if tool == TOOL_ERASER then
        return { tool = tool, width = eraser_width, eraser_width = eraser_width }
    end
    local ts = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]
    return { tool = tool, color_name = ts.color_name, width = ts.width, eraser_width = eraser_width,
             opacity = tool == TOOL_HIGHLIGHTER and alphaToOpacity(ts.alpha) or nil }
end

-- Make `st` the tool in hand. Only the fields it carries change: { tool = "pen" }
-- picks the pen as it was last set, a preset also sets color and width. Does
-- not save or announce anything.
function Pencil:applyToolState(st)
    if st.tool == TOOL_ERASER then
        if Toolset.isValidWidth(st.width) then
            self.tool_settings[TOOL_ERASER].width = st.width
        end
        self.current_tool = TOOL_ERASER
        return
    end
    local ts = self.tool_settings[st.tool]
    if not ts then return end
    local color = st.color_name and self:findColor(st.tool, st.color_name)
    if color then
        ts.color, ts.color_name = color, st.color_name
    end
    if Toolset.isValidWidth(st.width) then
        ts.width = st.width
    end
    -- Only the opacities the menus offer, like setHighlighterOpacity
    if st.tool == TOOL_HIGHLIGHTER and st.opacity then
        for _, allowed in ipairs(HIGHLIGHTER_OPACITIES) do
            if allowed == st.opacity then
                ts.alpha = opacityToAlpha(allowed)
                break
            end
        end
    end
    self.current_tool = st.tool
end

-- Change tool, remembering the one before for "swap to previous tool".
function Pencil:switchTool(st)
    local before = self:getToolState()
    self:applyToolState(st)
    local after = self:getToolState()
    self.prev_tool_state = Toolset.remember(before, after, self.prev_tool_state)
    if not Toolset.same(before, after) then
        self:saveSettings()
    end
end

-- The plugin side of the tool box: everything the widget needs, nothing more.
function Pencil:makeToolBoxProvider()
    local plugin = self
    return {
        getState = function() return plugin:getToolState() end,
        getPresets = function() return plugin.tool_presets end,
        colorsFor = function(tool)
            return tool == TOOL_HIGHLIGHTER and plugin.highlight_colors or plugin.available_colors
        end,
        colorFor = function(tool, name) return plugin:findColor(tool, name) end,
        setTool = function(tool) plugin:switchTool({ tool = tool }) end,
        setColor = function(name)
            local tool = plugin.current_tool
            if tool ~= TOOL_ERASER then
                plugin:applyToolState({ tool = tool, color_name = name })
                plugin:saveSettings()
            end
        end,
        setWidth = function(width)
            local tool = plugin.current_tool
            if tool ~= TOOL_ERASER then
                plugin:applyToolState({ tool = tool, width = width })
                plugin:saveSettings()
            end
        end,
        opacities = function() return HIGHLIGHTER_OPACITIES end,
        setOpacity = function(percent) plugin:setHighlighterOpacity(percent) end,
        setEraserWidth = function(width)
            if Toolset.isValidWidth(width) then
                plugin.tool_settings[TOOL_ERASER].width = width
                plugin:saveSettings()
            end
        end,
        selectPreset = function(idx)
            local p = plugin.tool_presets[idx]
            if p then
                plugin:switchTool({ tool = p.tool, color_name = p.color_name, width = p.width,
                                    opacity = p.opacity })
            end
        end,
        -- store the tool in hand in slot idx (one past the end adds a slot)
        savePreset = function(idx)
            local st = plugin:getToolState()
            if st.tool == TOOL_ERASER then return end
            local stored = Toolset.store(plugin.tool_presets, idx,
                { tool = st.tool, color_name = st.color_name, width = st.width, opacity = st.opacity },
                plugin.valid_color_names)
            if stored then plugin:saveSettings() end
        end,
        undo = function() plugin:undoLastStroke() end,
        canUndo = function() return #plugin.undo_stack > 0 end,
    }
end

-- The tool box widget class, loaded on first use. A failure to load it (say, a
-- KOReader too old for a widget it uses) only loses the box, never the pen.
function Pencil:loadToolBoxClass()
    if self._ToolBoxClass == nil then
        local ok, mod = pcall(require, "lib/toolbox")
        if not ok then
            local err = mod
            ok, mod = pcall(require, "toolbox")
            if not ok then logger.err("Pencil: tool box failed to load:", err) end
        end
        self._ToolBoxClass = ok and mod or false
    end
    return self._ToolBoxClass or nil
end

-- Take the dot a held-still pen left out of the in-progress stroke and off the
-- screen. Repaints the page into the framebuffer, but refreshes only the dot.
function Pencil:discardCurrentStroke()
    local stroke = self.current_stroke
    if not stroke then return end
    self.current_stroke, self.live_highlighter = nil, nil
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if bbox then
        bbox = PencilGeometry.bboxExpand(bbox, math.floor((stroke.width or 3) / 2) + 4)
        bbox = PencilGeometry.bboxClampToScreen(bbox, Screen:getWidth(), Screen:getHeight())
        local w, h = bbox.x1 - bbox.x0, bbox.y1 - bbox.y0
        if w > 0 and h > 0 then
            Screen:refreshUI(bbox.x0, bbox.y0, w, h)
            return
        end
    end
    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
end

-- Open the tool box near (x, y), or at the bottom of the screen without a point.
function Pencil:showToolBox(x, y)
    if self.tool_box_widget then return end
    local ToolBox = self:loadToolBoxClass()
    if not ToolBox then
        self:showToast(_("The tool box could not be loaded."))
        return
    end
    -- A hold-still leaves a dot in the stroke being drawn: that was not drawing
    self:discardCurrentStroke()
    -- Also keeps the hold-still check from opening a second box
    self.color_picker_showing = true

    local plugin = self
    local box = ToolBox:new{
        provider = self:makeToolBoxProvider(),
        anchor_x = x,
        anchor_y = y,
        on_close = function()
            plugin.tool_box_widget = nil
            plugin.color_picker_showing = false
        end,
    }
    self.tool_box_widget = box
    UIManager:show(box, "ui", box.dimen)
end

function Pencil:closeToolBox()
    if self.tool_box_widget then
        self.tool_box_widget:close()
    end
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()


    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    local color = tool_settings.color
    if effective_tool == TOOL_HIGHLIGHTER then
        self:drawLiveHighlighter(self.current_stroke, ges.pos.x, ges.pos.y, ges.pos.x, ges.pos.y)
    else
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)
    end

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == TOOL_TYPE_PEN then
            return true, false, false
        elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
            return true, true, false
        elseif pen_slot_data.tool == TOOL_TYPE_HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end, is_highlighter)
    if self.swap_eraser_and_highlighter then
        -- Swapped drag roles: the side button erases and the physical eraser
        -- end highlights. Side-button clicks are handled separately.
        if self.eraser_role_active or is_highlighter then return TOOL_ERASER end
        if self.eraser_tool_active or is_eraser_end then return TOOL_HIGHLIGHTER end
    else
        if self.eraser_role_active or self.eraser_tool_active or is_eraser_end then
            return TOOL_ERASER
        end
        if self.side_button_down or is_highlighter then return TOOL_HIGHLIGHTER end
    end
    return self.current_tool
end

-- Find the topmost visible pencil annotation group at a screen position.
-- Stale-rotation groups are excluded because their saved bbox is not valid in
-- the current layout; those remain accessible through their rotation badge.
function Pencil:findAnnotationGroupAtPoint(x, y)
    local page = self:getCurrentPage()
    local rotation = Screen:getRotationMode()
    local groups = self.annotation_groups or {}
    for i = #groups, 1, -1 do
        local group = groups[i]
        local bbox = group.bbox
        local same_rotation = group.image_rotation == nil
            or group.image_rotation == rotation
        if bbox and same_rotation and self:getGroupCurrentPage(group) == page
                and x >= bbox.x0 - ANNOTATION_HOLD_HIT_PAD
                and x <= bbox.x1 + ANNOTATION_HOLD_HIT_PAD
                and y >= bbox.y0 - ANNOTATION_HOLD_HIT_PAD
                and y <= bbox.y1 + ANNOTATION_HOLD_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Show annotation actions after a priority long press.
function Pencil:showAnnotationHoldMenu(group)
    if not group then return end

    local dialog
    local text = trimString(group.transcription)
    local rows = {}

    if text ~= "" then
        rows[#rows + 1] = {{
            text = _("Show recognized text"),
            callback = function()
                UIManager:close(dialog)
                self:showRecognizedText(text, group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Edit recognized text"),
            callback = function()
                UIManager:close(dialog)
                self:showAnnotationTextEditor(group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Recognize again"),
            callback = function()
                UIManager:close(dialog)
                self:recognizeAnnotationGroup(group)
            end,
        }}
    else
        rows[#rows + 1] = {{
            text = _("Create text"),
            callback = function()
                UIManager:close(dialog)
                self:showAnnotationTextEditor(group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Recognize this annotation"),
            callback = function()
                UIManager:close(dialog)
                self:recognizeAnnotationGroup(group)
            end,
        }}
    end

    if group.image_path then
        rows[#rows + 1] = {{
            text = _("Show saved image"),
            callback = function()
                UIManager:close(dialog)
                self:showGroupImagePreview(group)
            end,
        }}
    end

    rows[#rows + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }}

    dialog = ButtonDialog:new{
        title = T(_("Pencil annotation - page %1"), self:getPageNumber(group.page)),
        buttons = rows,
    }
    UIManager:show(dialog)
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("Pencil: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            self:commitErase(erased)
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    self:commitStroke(stroke)
    self:saveStrokes()

    -- Add to undo stack
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end
    if self.side_button_down and ges and ges.pos then
        self:trackSideButtonContact(ges.pos.x, ges.pos.y)
    end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)


    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_deleted then
            self.eraser_deleted = {}
        end

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self.view:paintTo(Screen.bb, 0, 0)
            local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
            if rx then
                Screen:refreshUI(rx, ry, rw, rh)
            else
                Screen:refreshUI()
            end
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("Pencil: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawLiveHighlighter(self.current_stroke, p1.x, p1.y, p2.x, p2.y)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawLiveHighlighter(self.current_stroke, p.x, p.y, p.x, p.y)
        else
            local half_w = math.floor(width / 2)
            Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
        end
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            self:commitErase(self.eraser_deleted)
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
        self.eraser_deleted = nil
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        self:commitStroke(self.current_stroke)
        self:saveStrokes()

        -- Add to undo stack
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
        self:accumulateRefreshBbox(self.current_stroke)
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents, convert XPointer to stable page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Add a finished stroke to the list and the page index, and record its page
-- coordinates for PDF export while its page is still the one on screen
-- (skipped when `view_moved`). Every drawing path commits through here.
function Pencil:commitStroke(stroke, view_moved)
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, stroke.page)
    if not view_moved then self:recordPagePoints(stroke) end
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        -- Drop bookmarks still queued for the old groups. Without this, ink
        -- erased before its queued bookmark was added left a bookmark (and the
        -- page's folded corner) behind. Regrouping below re-queues every group
        -- that still has ink.
        self.dirty_groups = nil

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx)
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), a valid XPointer, or nil. KOReader can't sort
-- an invalid one. Two make its sort fail and the book won't open (#84).
function Pencil:getBookmarkPageRef(group)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        local doc = self.ui.document
        local function valid(xp)
            return type(xp) == "string" and xp ~= "" and doc:isXPointerInDocument(xp)
        end
        -- The ink's own XPointer. It follows the ink through font changes
        -- and rotation.
        if valid(group.xpointer) then
            return group.xpointer
        end
        -- The page's start. Past the end of the book this is "".
        local xp = doc:getPageXPointer(group.page)
        if valid(xp) then
            return xp
        end
        return nil
    end
    return group.page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local bookmark_page = self:getBookmarkPageRef(group)
        if not bookmark_page then
            logger.dbg("Pencil: no valid position for group", group.id, "- no bookmark")
            return
        end
        local pageno = self:getPageNumber(bookmark_page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local transcription = trimString(group.transcription)
        local bookmark_text

        if transcription ~= "" then
            bookmark_text = transcription
        else
            bookmark_text = string.format(
                "Pencil annotation on page %d",
                pageno
            )
        end

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = bookmark_text,
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- MyScript handwriting recognition
------------------------------------------------------------------------------

function Pencil:showMyScriptSettingsDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MyScript settings"),
        fields = {
            { description = _("Recognition language"), text = self.myscript_language or "en_US", hint = "en_US" },
            { description = _("Application key"), text = self.myscript_application_key or "" },
            { description = _("HMAC key"), text = self.myscript_hmac_key or "", text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local lang, app, hmac = trimString(f[1]), trimString(f[2]), trimString(f[3])
                if lang == "" or app == "" or hmac == "" then
                    UIManager:show(InfoMessage:new{ text = _("Language, application key, and HMAC key are required."), timeout = 3 })
                    return
                end
                self.myscript_language, self.myscript_application_key, self.myscript_hmac_key = lang, app, hmac
                self:saveSettings(); UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = _("MyScript settings saved."), timeout = 2 })
            end },
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Pencil:getLatestAnnotationGroupOnCurrentPage()
    local page, latest = self:getCurrentPage(), nil
    for _, g in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(g) == page and (not latest or (g.datetime_last or g.datetime or 0) > (latest.datetime_last or latest.datetime or 0)) then latest = g end
    end
    return latest
end

function Pencil:getMyScriptStrokesForGroup(group)
    local MyScript = require("lib/myscript")
    if not group or type(group.stroke_indices) ~= "table" then return nil, { message = "Invalid annotation group" } end
    return MyScript.strokes_from_pencil({ strokes = self.strokes, annotation_groups = { group } }, { group_index = 1, pointer_type = "PEN", pointer_id = 0 })
end

function Pencil:showRecognizedText(text, group)
    UIManager:show(TextViewer:new{
        title = T(_("Handwriting - page %1"), self:getPageNumber(group.page)),
        text = text,
        text_settings = {},
    })
end

function Pencil:createMyScriptClient()
    local MyScript = require("lib/myscript")
    return MyScript.new{
        application_key = self.myscript_application_key,
        hmac_key = self.myscript_hmac_key,
        language = self.myscript_language,
        content_type = "Text",
        client_name = "koreader-pencil-plugin",
        client_version = "1.1.0",
    }
end

-- Store text on the group and on every stroke referenced by the group.
-- A stroke keeps group id + text, which avoids ambiguity if groups are rebuilt.
function Pencil:setAnnotationGroupText(group, text, engine)
    text = trimString(text)
    if not group or text == "" then return false end

    local updated_at = os.time()
    local source = engine or "manual"
    group.transcription = text
    group.transcription_language = self.myscript_language
    group.transcription_datetime = updated_at
    group.transcription_engine = source

    for _, stroke_index in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[stroke_index]
        if stroke then
            stroke.transcription = text
            stroke.transcription_group_id = group.id
            stroke.transcription_language = self.myscript_language
            stroke.transcription_datetime = updated_at
            stroke.transcription_engine = source
        end
    end

    if self.experimental_bookmark_sync then
        self:syncGroupBookmark(group)
    end
    return true
end

function Pencil:enrichAnnotationGroup(group, text)
    return self:setAnnotationGroupText(group, text, "myscript")
end

function Pencil:showAnnotationTextEditor(group)
    if not group then return end

    local dialog
    local existing_text = trimString(group.transcription)
    dialog = MultiInputDialog:new{
        title = existing_text ~= ""
            and _("Edit annotation text")
            or _("Create annotation text"),
        fields = {{
            description = _("Text"),
            text = existing_text,
            hint = _("Enter annotation text"),
        }},
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local fields = dialog:getFields()
                local edited_text = trimString(fields and fields[1])
                if edited_text == "" then
                    UIManager:show(InfoMessage:new{
                        text = _("Annotation text cannot be empty."),
                        timeout = 2,
                    })
                    return
                end
                self:setAnnotationGroupText(group, edited_text, "manual")
                self:saveStrokes()
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = _("Annotation text saved."),
                    timeout = 2,
                })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Pencil:recognizeGroupWithClient(client, group)
    local strokes, conversion_error = self:getMyScriptStrokesForGroup(group)
    if not strokes then
        return nil, conversion_error
    end

    local ok, text, api_error = pcall(client.recognize_text, client, strokes, {
        language = self.myscript_language,
    })
    if not ok then
        logger.warn("Pencil: MyScript call failed:", tostring(text))
        return nil, { message = tostring(text), kind = "unexpected" }
    end
    text = trimString(text)
    if text == "" then
        return nil, api_error or { message = _("No text was recognized.") }
    end

    self:enrichAnnotationGroup(group, text)
    return text
end

function Pencil:recognizeAnnotationGroup(group)
    local NetworkMgr = require("ui/network/manager")
    if trimString(self.myscript_application_key) == ""
            or trimString(self.myscript_hmac_key) == "" then
        self:showMyScriptSettingsDialog()
        return
    end

    NetworkMgr:runWhenOnline(
        function()
            local client, client_error = self:createMyScriptClient()
            if not client then
                UIManager:show(InfoMessage:new{
                                   text = T(_("Invalid MyScript configuration: %1"), tostring(client_error)),
                })
                return
            end

            UIManager:show(InfoMessage:new{
                               text = _("Recognizing handwriting..."),
                               timeout = 1,
            })

            -- Run recognition in a subprocess to avoid blocking UI
            local _pid, pipe_fd = util.runInSubProcess(
                function(_child_pid, write_fd)
                    local text, error_value = self:recognizeGroupWithClient(client, group)
                    local result = { text = text, error_value = error_value }
                    -- Serialize result as JSON for communication
                    local json = require("json")
                    local output = json.encode(result)
                    util.writeToFD(write_fd, output, true)
                end,
                true, false)

        if pipe_fd then
            local json = require("json")
            local function check_pipe()
                local avail = util.getNonBlockingReadSize(pipe_fd)
                if avail and avail > 0 then
                    -- Now safe to read all and block, since data is ready
                    local output = util.readAllFromFD(pipe_fd)
                    local result = json.decode(output)
                    if not result.text then
                        local message = result.error_value and result.error_value.message or result.error_value
                        UIManager:show(InfoMessage:new{
                            text = T(_("Recognition failed: %1"), tostring(message)),
                        })
                        return
                    end
                    group.transcription = result.text
                    group.transcription_language = self.myscript_language
                    self:saveStrokes()
                    self:showRecognizedText(result.text, group)
                else
                    -- Schedule next check (using KOReader's timer)
                    UIManager:scheduleIn(0.1, check_pipe)
                end
            end
            check_pipe()
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to start recognition subprocess."),
            })
        end
    end)
end

function Pencil:hasRecognizedAnnotations()
    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then return true end
    end
    return false
end

function Pencil:getAllRecognizedText()
    local gettext = _
    local groups = {}

    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then
            groups[#groups + 1] = group
        end
    end

    table.sort(groups, function(a, b)
                   local ap, bp = self:getPageNumber(a.page), self:getPageNumber(b.page)

                   if ap ~= bp then
                       return ap < bp
                   end

                   return (a.datetime or 0) < (b.datetime or 0)
    end)

    local parts = {}

    for index, group in ipairs(groups) do
        parts[#parts + 1] =
            T(gettext("Page %1"), self:getPageNumber(group.page))
            .. "\n"
            .. trimString(group.transcription)
    end

    return table.concat(parts, "\n\n")
end

function Pencil:showAllRecognizedText()
    local text = self:getAllRecognizedText()
    if text == "" then
        UIManager:show(InfoMessage:new{ text = _("No recognized annotations.") })
        return
    end
    UIManager:show(TextViewer:new{
        title = _("Recognized annotations"),
        text = text,
        text_settings = {},
    })
end


-- Edit every annotation that currently has text. One MultiInput field is bound
-- to one group directly, avoiding fragile parsing of page labels or separators.
function Pencil:editAllRecognizedText()
    local groups = {}
    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then
            groups[#groups + 1] = group
        end
    end
    table.sort(groups, function(a, b)
        local ap, bp = self:getPageNumber(a.page), self:getPageNumber(b.page)
        if ap ~= bp then return ap < bp end
        return (a.datetime or 0) < (b.datetime or 0)
    end)

    if #groups == 0 then
        UIManager:show(InfoMessage:new{ text = _("No recognized annotations.") })
        return
    end

    local fields = {}
    for index, group in ipairs(groups) do
        fields[index] = {
            description = T(_("Page %1 - annotation %2"),
                self:getPageNumber(group.page), index),
            text = trimString(group.transcription),
            hint = _("Enter annotation text"),
        }
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _("Edit all recognized text"),
        fields = fields,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save all"), is_enter_default = true, callback = function()
                local values = dialog:getFields()
                if not values or #values ~= #groups then
                    UIManager:show(InfoMessage:new{
                        text = _("Unable to read all annotation fields."),
                        timeout = 2,
                    })
                    return
                end

                -- Validate the whole form before mutating any group, so a single
                -- empty field cannot leave a partially updated document.
                local normalized = {}
                for index = 1, #groups do
                    normalized[index] = trimString(values[index])
                    if normalized[index] == "" then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Text for annotation %1 cannot be empty."), index),
                            timeout = 3,
                        })
                        return
                    end
                end

                local changed = 0
                for index, group in ipairs(groups) do
                    if normalized[index] ~= trimString(group.transcription) then
                        self:setAnnotationGroupText(group, normalized[index], "manual")
                        changed = changed + 1
                    end
                end
                if changed > 0 then self:saveStrokes() end
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = T(_("Updated %1 annotation(s)."), changed),
                    timeout = 3,
                })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Recognize every current annotation group, enrich groups and their referenced
-- strokes, then persist once. Processing continues after per-group failures.
function Pencil:recognizeAllAnnotationGroups()
    local NetworkMgr = require("ui/network/manager")
    if trimString(self.myscript_application_key) == ""
            or trimString(self.myscript_hmac_key) == "" then
        self:showMyScriptSettingsDialog()
        return
    end
    if not self.annotation_groups or #self.annotation_groups == 0 then
        UIManager:show(InfoMessage:new{ text = _("No annotation groups to recognize.") })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local client, client_error = self:createMyScriptClient()
        if not client then
            UIManager:show(InfoMessage:new{
                text = T(_("Invalid MyScript configuration: %1"), tostring(client_error)),
            })
            return
        end

        local recognized, failed = 0, 0
        UIManager:show(InfoMessage:new{
            text = T(_("Recognizing %1 annotation group(s)..."), #self.annotation_groups),
            timeout = 1,
        })

        for group_index, group in ipairs(self.annotation_groups) do
            local text, error_value = self:recognizeGroupWithClient(client, group)
            if text then
                group.transcription_error = nil
                recognized = recognized + 1
            else
                local message = error_value and error_value.message or error_value
                group.transcription_error = tostring(message or _("Unknown recognition error"))
                group.transcription_error_datetime = os.time()
                failed = failed + 1
                logger.warn("Pencil: recognition failed for group", group_index,
                    group.id or "(no id)", group.transcription_error)
            end
        end

        -- Persist all group fields and all stroke-level enrichment atomically
        -- through the plugin's existing sidecar serialization path.
        self:saveStrokes()

        local summary = T(_("Recognized %1 annotation group(s)."), recognized)
        if failed > 0 then
            summary = summary .. "\n" .. T(_("Failed: %1."), failed)
        end
        UIManager:show(InfoMessage:new{ text = summary, timeout = 4 })
    end)
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("Pencil: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("Pencil: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("Pencil: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("Pencil: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("Pencil: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("Pencil: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

-- Variant of renderStroke that translates points by (dx, dy) before drawing.
-- Used during capture to render a group's strokes onto an offscreen buffer
-- whose origin corresponds to the bbox top-left.
function Pencil:renderStrokeOffset(bb, stroke, dx, dy)
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    if tool == TOOL_HIGHLIGHTER then
        self:paintHighlighterStroke(bb, stroke, dx, dy)
        return
    end
    if #stroke.points == 1 then
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x + dx - half_w, p.y + dy - half_w, width, width, color)
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            self:drawLineSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
        end
    end
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb = function()
        self.pending_image_captures[group.id] = nil
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("Pencil: captureGroupImage error:", err)
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:saveStrokes()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("Pencil: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    if not self.pending_image_captures then return end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("Pencil: flushPendingCaptures error:", err)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("Pencil: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Called by the bookmark-list hook on menu select. Returns true if we
-- handled the tap (and the original navigation should be skipped).
function Pencil:tryShowImageForBookmark(item)
    if not item or not item.datetime then return false end
    if not item.datetime:match("^pencil_") then return false end
    -- Find the matching group by id (group.id is stored as the bookmark datetime).
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.id == item.datetime then
            if group.image_path then
                self:showGroupImagePreview(group)
                return true
            end
            return false  -- pencil bookmark but no image yet; fall through to navigate
        end
    end
    return false
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page and not group.image_path then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("Pencil: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("Pencil: installed bookmark list hook")
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return self.page_strokes[page] and #self.page_strokes[page] > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices_to_remove = self.page_strokes[page]

    if not indices_to_remove or #indices_to_remove == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    -- Copy and sort in reverse order to maintain indices during removal
    local sorted_indices = {}
    for _, idx in ipairs(indices_to_remove) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return a > b end)

    local deleted_strokes = {}
    for _, idx in ipairs(sorted_indices) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    -- Same as finishing an erase: undo entry, PDF ink removed (undo then
    -- restores the strokes as overlay ink that re-embeds on the next save),
    -- bookmarks, page corner and save.
    self:commitErase(deleted_strokes)

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    -- Remove every stroke's ink from the PDF as well.
    self:deleteEmbeddedAnnotationsFor(self.strokes)
    self.strokes = {}
    self.page_strokes = {}
    self.annotation_groups = {}
    self:refreshDogear()
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    UIManager:setDirty(self.view, "ui")
end

-- ===================================================================
-- Save annotations to PDF (issue #63)
--
-- Converts pencil strokes into native PDF ink annotations (/Subtype /Ink)
-- so they're visible in any PDF reader. Strokes are stored in screen
-- coordinates; each stroke also records its points in native page
-- coordinates when it is drawn (capturePagePoints), and those are what get
-- handed to MuPDF. All edits stay in memory until a single write on close
-- (flushPdfEdits).
--
-- Requires KOReader 2026.07+ for the ink setters (see the module InkAnnot
-- block near the top). Degrades gracefully: when InkAnnot is nil the menu
-- action explains what's missing.
-- ===================================================================

-- True when the open document is an actual .pdf file. `is_pdf` alone isn't
-- enough: PdfDocument is the provider for every MuPDF format (XPS, CBZ, FB2,
-- MOBI, DOCX, ...) and sets it on the class. Walking a non-PDF page as a
-- pdf_page* reads memory that isn't an annotation list (likely a segfault
-- pcall can't catch), so everything that touches MuPDF annotations gates on
-- this. _checkIfWritable() returns nil for anything that isn't a .pdf, and
-- true/false for a writable or read-only .pdf.
function Pencil:isPdfDocument()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf == true and doc._checkIfWritable) then return false end
    return doc:_checkIfWritable() ~= nil
end

-- True when this document's ink can be exported: a real .pdf on a KOReader
-- build with the ink setters. Page coordinates are only worth recording then;
-- for everything else they'd just double what saveStrokes writes per stroke.
function Pencil:canExportInk()
    return InkAnnot ~= nil and self:isPdfDocument()
end

-- The document, when PDF annotations can be written into it now: a writable
-- .pdf on a build with ink support. Otherwise nil, plus _checkIfWritable()'s
-- reason when the .pdf itself is read-only.
function Pencil:writablePdfDoc()
    if not self:canExportInk() then return nil end
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return nil, can_write end
    return doc
end

-- { [tag] = page } -> { [page] = { [tag] = true } }, the shape the per-page
-- deletion walk takes.
local function groupTagsByPage(tag_pages)
    local by_page = {}
    for tag, page in pairs(tag_pages) do
        by_page[page] = by_page[page] or {}
        by_page[page][tag] = true
    end
    return by_page
end

-- Round a page coordinate to 1/100 of a point: far below any visible
-- difference, and keeps the packed sidecar string short.
local function roundPageCoord(v)
    return math.floor(v * 100 + 0.5) / 100
end

-- Whether the document is shown reflowed (text_wrap). Then screenToPageTransform
-- maps to the reflowed page, not the original one, so its coordinates can't be
-- used for the PDF.
function Pencil:isReflowed()
    local doc = self.ui and self.ui.document
    return doc ~= nil and type(doc.configurable) == "table" and doc.configurable.text_wrap == 1
end

-- Record a stroke's points in native page coordinates, plus the zoom it was
-- drawn at. Called when a stroke is committed (its page is the one on screen,
-- so the live ReaderView transform is the one the stroke was drawn under) and,
-- for strokes saved before this existed, the first time their page is painted.
-- Embedding then uses these instead of whatever page happens to be on screen
-- at close, so mixed page sizes and later zoom/pan can't misplace the ink.
-- Every point must map to the stroke's own page; if any doesn't (e.g. scroll
-- mode put it on a neighbour or off-screen), nothing is recorded and the
-- stroke isn't embedded.
-- Nothing is recorded while the document is reflowed (see isReflowed).
-- transform_fn is injectable for testing. Returns true if points were recorded.
function Pencil:capturePagePoints(stroke, transform_fn)
    if stroke.page_points then return true end
    if stroke.page_points == false then return false end
    if not transform_fn then
        if not (self.ui and self.ui.paging and self.view and self:canExportInk()) then
            return false
        end
        if self:isReflowed() then return false end
        -- Paging-mode transforms only read pos.x/pos.y and return a new
        -- table, so the stroke's own points can be passed straight through.
        local view = self.view
        transform_fn = function(pt) return view:screenToPageTransform(pt) end
    end
    local src = stroke.points
    if not src or #src == 0 then return false end
    local points, zoom = {}, nil
    for i = 1, #src do
        local pp = transform_fn(src[i])
        if not (pp and pp.x and pp.y) then return false end
        if pp.page ~= nil and pp.page ~= stroke.page then return false end
        zoom = zoom or pp.zoom
        points[i] = { x = roundPageCoord(pp.x), y = roundPageCoord(pp.y) }
    end
    stroke.page_points = points
    stroke.page_zoom = zoom
    return true
end

-- capturePagePoints for a stroke that has just been drawn. A stroke drawn
-- while reflowed is marked page_points = false (persisted): its screen
-- coordinates belong to the reflowed layout, so no later backfill may map
-- them once reflow is off. It stays overlay ink.
function Pencil:recordPagePoints(stroke)
    if self:canExportInk() and self:isReflowed() then
        stroke.page_points = false
        return false
    end
    return self:capturePagePoints(stroke)
end

-- Derive the ink annotation options (color/width/opacity) for a stroke.
-- Stroke widths are stored in screen pixels, but MuPDF's border width is in
-- native page units, so it needs the same zoom division the points got. We use
-- the zoom the stroke was drawn at, falling back to the live zoom for strokes
-- recorded before that was stored. (MuPDF's ink border width is the full line
-- width, centered on the path, so no extra halving is needed.)
function Pencil:strokeToInkOpts(stroke)
    local tool = stroke.tool or TOOL_PEN
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK
    local rgb = color:getColorRGB32()
    local width = stroke.width or self.tool_settings[tool].width or 3
    local zoom = stroke.page_zoom
    if not (zoom and zoom > 0) then
        zoom = self.view and self.view.state and self.view.state.zoom
    end
    if zoom and zoom > 0 then
        width = width / zoom
    end
    return {
        color = { r = rgb:getR(), g = rgb:getG(), b = rgb:getB() },
        width = width,
        -- Highlighter renders as a translucent wash; the pen is opaque.
        opacity = (tool == TOOL_HIGHLIGHTER) and 0.4 or 1.0,
    }
end

-- Tag prefix carried in each embedded ink annotation's /Contents. Lets us
-- recognise (and only ever delete) annotations this plugin created.
local INK_TAG_PREFIX = "kop-ink-"

-- Delete the ink annotations on the already-open `page` whose /Contents tag
-- is in `tags` (a set). Only the given tags are touched: ink from other apps,
-- and plugin ink this sidecar doesn't own (e.g. drawn on another device), is
-- never deleted. Returns the number deleted.
local function deleteTaggedInk(page, tags)
    if next(tags) == nil then return 0 end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local deleted = 0
    local annot = W.mupdf_pdf_first_annot(ctx, pdf_page)
    while annot ~= nil do
        -- Grab next before a possible delete unlinks the current one.
        local next_annot = W.mupdf_pdf_next_annot(ctx, annot)
        if W.mupdf_pdf_annot_type(ctx, annot) == InkAnnot.PDF_ANNOT_INK then
            local cptr = W.mupdf_pdf_annot_contents(ctx, annot)
            local tag = cptr ~= nil and ffi.string(cptr) or ""
            if tag:sub(1, #INK_TAG_PREFIX) == INK_TAG_PREFIX and tags[tag] then
                page:deleteAnnotation(annot)  -- raises if MuPDF refuses
                deleted = deleted + 1
            end
        end
        annot = next_annot
    end
    return deleted
end

-- Build one tagged ink annotation on an already-open `page` from `points`
-- (native page coordinates). Talks to the MuPDF wrapper directly because
-- stock addInkAnnotation doesn't return the annotation handle, so we couldn't
-- tag it for the eraser. Every setter's result is checked, like stock
-- addMarkupAnnotation does: an annotation missing its ink, tag or /AP would be
-- invisible or unerasable, so on any failure the half-built annotation is
-- deleted and false returned (the stroke then stays overlay ink).
local function buildInkAnnot(page, points, opts)
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local n = #points
    local counts = ffi.new("int[1]")
    counts[0] = n
    local vertices = ffi.new("fz_point[?]", n)
    for i = 1, n do
        vertices[i - 1].x = points[i].x
        vertices[i - 1].y = points[i].y
    end
    local color = ffi.new("float[3]")
    color[0] = opts.color.r / 255
    color[1] = opts.color.g / 255
    color[2] = opts.color.b / 255

    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, InkAnnot.PDF_ANNOT_INK)
    if annot == nil then return false end
    local ok = W.mupdf_pdf_set_annot_ink_list(ctx, annot, 1, counts, vertices)
        and W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        and W.mupdf_pdf_set_annot_border_width(ctx, annot, opts.width or 1.0)
        and W.mupdf_pdf_set_annot_opacity(ctx, annot, opts.opacity or 1.0)
        -- The tag in /Contents is how erase, undo and clear find it later.
        and W.mupdf_pdf_set_annot_contents(ctx, annot, opts.annot_id)
        -- Synthesize the /Rect and /AP appearance stream, so the annotation
        -- renders in any PDF viewer (not just KOReader's geometry renderer).
        and W.mupdf_pdf_update_annot(ctx, annot)
    if not ok then
        page:deleteAnnotation(annot)
        return false
    end
    return true
end

-- Whether a stroke still needs embedding (neither in the file nor staged).
local function needsEmbedding(stroke)
    return stroke.page ~= nil and not stroke.embedded and not stroke.staged
end

-- Stage the given strokes' ink into the in-memory document. Staged strokes
-- are marked `staged` (in memory only, never persisted) rather than
-- `embedded`: the file isn't written until flushPdfEdits() on close, and the
-- sidecar must not claim the ink is in the file before it is.
-- settleStagedStrokes() promotes them to `embedded` once the write succeeds,
-- or un-stages them so they're retried.
--
-- Work is grouped by page: each page is opened once, any earlier copies of
-- these strokes' own tags are removed in a single walk (so re-staging after a
-- failed close can't duplicate), all new annotations are built, and the tile
-- cache is reset once at the end. Strokes without page coordinates, or whose
-- annotation MuPDF couldn't build, are skipped and stay overlay ink.
-- Returns the number staged and the _checkIfWritable() reason, if any.
function Pencil:stageStrokesInk(strokes)
    local doc, reason = self:writablePdfDoc()
    if not doc then return 0, reason end

    local by_page, pages = {}, {}
    for _, stroke in ipairs(strokes) do
        local points = needsEmbedding(stroke) and stroke.page_points
        if points then
            if not by_page[stroke.page] then
                by_page[stroke.page] = {}
                pages[#pages + 1] = stroke.page
            end
            table.insert(by_page[stroke.page], { stroke = stroke, points = points })
        end
    end

    local staged = 0
    for _, pageno in ipairs(pages) do
        local entries = by_page[pageno]
        local old_tags = {}
        for _, e in ipairs(entries) do
            if e.stroke.annot_id then old_tags[e.stroke.annot_id] = true end
        end
        local page
        local ok, err = pcall(function()
            page = doc._document:openPage(pageno)
            deleteTaggedInk(page, old_tags)
            for _, e in ipairs(entries) do
                local opts = self:strokeToInkOpts(e.stroke)
                opts.annot_id = e.stroke.annot_id or self:nextAnnotId()
                if buildInkAnnot(page, e.points, opts) then
                    -- Keep the tag even if the write later fails: a retry
                    -- reuses it and replaces any copy that did reach the file.
                    e.stroke.annot_id = opts.annot_id
                    e.stroke.staged = true
                    staged = staged + 1
                else
                    logger.warn("Pencil: could not build ink annotation on page", pageno)
                end
            end
        end)
        if page then page:close() end
        if not ok then logger.warn("Pencil: staging ink failed on page", pageno, err) end
    end

    if staged > 0 then
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
    end
    return staged
end

-- Resolve every stroke staged this session once the close flush has run:
-- `written` true promotes them to `embedded` (they're in the file now);
-- false un-stages them so the overlay keeps drawing them and the next close
-- retries. Every path that removes a stroke (erase, undo, clear) un-stages it
-- first, so the staged strokes are exactly those still in self.strokes.
function Pencil:settleStagedStrokes(written)
    for _, stroke in ipairs(self.strokes) do
        if stroke.staged then
            stroke.staged = nil
            if written then stroke.embedded = true end
        end
    end
end

-- The part of a KOReader text highlight that lies on `pageno`, shaped the way
-- PdfDocument:saveHighlight/deleteHighlight expect, or nil. A single-page
-- highlight is its own part. A multi-page PDF highlight has no top-level
-- pboxes; each page's boxes live in item.ext[page], and the part comes from
-- KOReader's own getSavedExtendedHighlightPage, exactly as
-- ReaderHighlight:writePdfAnnotation does it (colour fallback included).
-- `commit` copies MuPDF's adjusted boxes back after a save.
local function noop() end
function Pencil:highlightPartOnPage(item, pageno)
    if not item.drawer then return nil end
    if item.ext then
        local ext = item.ext[pageno]
        local rh = self.ui.highlight
        if not (ext and ext.pboxes and #ext.pboxes > 0 and rh and rh.getSavedExtendedHighlightPage) then
            return nil
        end
        local part = rh:getSavedExtendedHighlightPage(item, pageno)
        return part, function() ext.pboxes = part.pboxes end
    end
    if item.page == pageno and item.pboxes and #item.pboxes > 0 then
        return item, noop
    end
    return nil
end

-- Collect this page's KOReader text highlights (text selections made with a
-- finger or the text-mode highlighter, stored in the sidecar) so they can be
-- embedded into the PDF as native markup annotations alongside the ink.
-- Returns a list of { part = <saveHighlight-shaped item>, commit = fn }.
function Pencil:getPageTextHighlights(pageno)
    local result = {}
    local annotation = self.ui and self.ui.annotation
    if not (annotation and annotation.annotations) then return result end
    for _, item in ipairs(annotation.annotations) do
        local part, commit = self:highlightPartOnPage(item, pageno)
        if part then result[#result + 1] = { part = part, commit = commit } end
    end
    return result
end

-- Whether the PDF page already holds a markup annotation with this
-- highlight part's exact quad points (the same match KOReader's
-- deleteHighlight uses), so re-running the manual save never stacks
-- duplicates. Callers must have checked canExportInk().
function Pencil:pdfHasHighlight(pageno, part)
    local ffi = InkAnnot.ffi
    local n = #part.pboxes
    -- pboxes {x,y,w,h} -> fz_quad[], same mapping as KOReader's
    -- _quadpointsFromPboxes (which isn't exported).
    local quads = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = part.pboxes[i]
        local q = quads[i - 1]
        q.ll.x = b.x;             q.ll.y = b.y + b.h - 1
        q.lr.x = b.x + b.w - 1;   q.lr.y = b.y + b.h - 1
        q.ul.x = b.x;             q.ul.y = b.y
        q.ur.x = b.x + b.w - 1;   q.ur.y = b.y
    end
    local page = self.ui.document._document:openPage(pageno)
    local ok, found = pcall(page.getMarkupAnnotation, page, quads, n)
    page:close()
    return ok and found ~= nil
end

-- Write this page's text highlights into the PDF with KOReader's own
-- saveHighlight (same quads, type, colour and /AP as "write highlights into
-- PDF", and it stores MuPDF's adjusted quads back so deleteHighlight can find
-- the annotation later). Highlights already present in the file are skipped.
-- Returns the number written and the _checkIfWritable() reason, if any.
function Pencil:saveTextHighlightsToPdf(pageno, highlights)
    if #highlights == 0 then return 0 end
    local doc, reason = self:writablePdfDoc()
    if not doc then return 0, reason end
    local saved = 0
    for _, h in ipairs(highlights) do
        local ok, res = pcall(function()
            if self:pdfHasHighlight(pageno, h.part) then return false end
            return doc:saveHighlight(pageno, h.part)
        end)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", res)
        elseif res == nil then
            -- PdfDocument:saveHighlight returns nothing on success.
            h.commit()
            saved = saved + 1
        end
    end
    if saved > 0 then self._pdf_dirty = true end
    return saved
end

-- Delete a text highlight's markup annotations from the PDF, on every page it
-- spans, wherever the file holds one with its exact quad points. Only runs on
-- a writable .pdf (see isPdfDocument: walking a non-PDF page would crash).
-- Returns the number deleted.
function Pencil:deleteHighlightFromPdf(item)
    local doc = item and self:writablePdfDoc()
    if not doc then return 0 end
    local pages = {}
    if item.ext then
        for pageno in pairs(item.ext) do pages[#pages + 1] = pageno end
    elseif item.page then
        pages[1] = item.page
    end
    local deleted = 0
    for _, pageno in ipairs(pages) do
        local part = self:highlightPartOnPage(item, pageno)
        if part and self:pdfHasHighlight(pageno, part) then
            doc:deleteHighlight(pageno, part)
            deleted = deleted + 1
        end
    end
    if deleted > 0 then doc:resetTileCacheValidity() end
    return deleted
end

-- Persist the plugin's in-memory PDF edits (ink/highlights created or deleted
-- this session) to disk with a SINGLE incremental writeDocument, mirroring how
-- KOReader itself batches all annotation edits into one write on close.
--
-- Critically it then clears doc.is_edited, so KOReader's own PdfDocument:close
-- does NOT issue a second writeDocument on the same document handle -- two
-- stacked incremental saves corrupt the xref (MuPDF: "cannot find object").
-- That single write also captures any in-memory highlight edits KOReader made
-- (e.g. via "write highlights into PDF"), so nothing is lost.
--
-- We write here, rather than leaving it to PdfDocument:close, because settling
-- the staged strokes needs the write's result before the sidecar is saved,
-- and KOReader's own write only happens after our CloseDocument handler. Two
-- side effects of doing it ourselves:
--   * this write skips PdfDocument:close's DocumentRegistry reference-count
--     check (KOReader only writes when it holds the last reference);
--   * anything that edits the document after our CloseDocument handler runs
--     is not written, since is_edited is already cleared.
-- Returns true if a write happened.
function Pencil:flushPdfEdits()
    if not self._pdf_dirty then return false end
    local doc = self.ui and self.ui.document
    if not (doc and doc.writeDocument) then return false end
    if not (doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return false
    end
    local ok, err = pcall(function() doc:writeDocument() end)
    if not ok then
        logger.err("Pencil: flushPdfEdits writeDocument failed:", err)
        return false
    end
    self._pdf_dirty = false
    doc.is_edited = false  -- prevent KOReader's close from writing again
    logger.info("Pencil: flushed plugin PDF edits (single write)")
    return true
end

-- Write the current page's pencil strokes (as ink) and text highlights (as
-- native markup annotations) into the PDF file.
function Pencil:saveCurrentPageToPdf()
    if not self:isPdfDocument() then
        UIManager:show(InfoMessage:new{
            text = _("Saving annotations to the file is only supported for PDF documents."),
            timeout = 3,
        })
        return
    end
    if not InkAnnot then
        UIManager:show(InfoMessage:new{
            text = _("This KOReader build cannot write ink annotations. Update to KOReader 2026.07 or newer."),
        })
        return
    end

    local page = self:getCurrentPage()
    local strokes = {}
    for _, stroke in ipairs(self:getStrokesForPage(page)) do
        if needsEmbedding(stroke) then strokes[#strokes + 1] = stroke end
    end
    -- With KOReader's "write highlights into PDF" on, highlights are already
    -- in the document; writing them again would only duplicate them.
    local highlights = {}
    if not (self.ui.highlight and self.ui.highlight.highlight_write_into_pdf) then
        highlights = self:getPageTextHighlights(page)
    end
    if #strokes == 0 and #highlights == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations on this page to save."),
            timeout = 2,
        })
        return
    end

    -- Pencil strokes -> ink annotations (one per stroke, keeping color/width).
    local saved_ink, writable_fail = self:stageStrokesInk(strokes)

    -- Text highlights -> native markup annotations (with appearance streams).
    local saved_hl, hl_fail = self:saveTextHighlightsToPdf(page, highlights)
    writable_fail = writable_fail or hl_fail

    local saved = saved_ink + saved_hl
    if saved == 0 then
        UIManager:show(InfoMessage:new{
            text = writable_fail
                and _("The PDF file is not writable, so annotations can't be saved.")
                or (#strokes == 0 and _("This page's highlights are already in the PDF."))
                or _("Failed to save annotations to the PDF."),
            timeout = 3,
        })
        return
    end

    -- The annotations are now in the in-memory document (visible immediately),
    -- but the actual file write is DEFERRED to a single write when the book is
    -- closed (see flushPdfEdits / onCloseDocument). Writing here as well would
    -- stack a second incremental save on the close write and corrupt the xref.
    -- Staged strokes are suppressed from the overlay (paintTo), so there's
    -- no double-draw to clean up and no prompt to remove them.
    UIManager:setDirty(self.view, "ui")

    local msg
    if saved_ink > 0 and saved_hl > 0 then
        msg = T(_("Added %1 pencil stroke(s) and %2 highlight(s) to this page."), saved_ink, saved_hl)
    elseif saved_ink > 0 then
        msg = T(_("Added %1 pencil stroke(s) to this page."), saved_ink)
    else
        msg = T(_("Added %1 highlight(s) to this page."), saved_hl)
    end
    UIManager:show(InfoMessage:new{
        text = msg .. "\n\n" .. _("They'll be written into the PDF file when you close the book."),
        timeout = 3,
    })
end

-- Generate a process-unique tag for an embedded ink annotation. Stored in the
-- annotation's /Contents and on the stroke, so the eraser can pair the two up.
function Pencil:nextAnnotId()
    self._annot_seq = (self._annot_seq or 0) + 1
    return string.format("%s%d-%d-%d", INK_TAG_PREFIX, os.time(), self._annot_seq, math.random(1000, 9999))
end

-- Remove the PDF ink annotations belonging to the given strokes, which have
-- just been erased, undone or cleared. Only those strokes' own tags are
-- deleted, so ink this sidecar doesn't know about (another device's, or from
-- before a reset) is always left alone. The delete is in memory; the disk
-- write is deferred to flushPdfEdits() on close. Each stroke's PDF state is
-- dropped so an undo brings it back as a normal overlay stroke that re-embeds
-- on the next save. Returns the number of annotations deleted.
function Pencil:deleteEmbeddedAnnotationsFor(strokes)
    -- Any stroke with a tag may have ink in the document (embedded, staged,
    -- or a write that landed before a crash).
    local tag_pages = {}
    for _, stroke in ipairs(strokes or {}) do
        if stroke.annot_id and stroke.page then tag_pages[stroke.annot_id] = stroke.page end
    end
    if next(tag_pages) == nil or not self:writablePdfDoc() then return 0 end

    -- Remember the deletions in the sidecar until the close write lands.
    -- The strokes leave the sidecar right away, so without this a crash or
    -- kill before close would leave their ink in the file with nothing left
    -- to erase it. The next session replays them (applyPendingInkDeletes).
    self.pending_ink_deletes = self.pending_ink_deletes or {}
    for tag, page in pairs(tag_pages) do self.pending_ink_deletes[tag] = page end

    local deleted = self:_deleteInkTagsByPage(groupTagsByPage(tag_pages))
    if deleted > 0 then
        -- The deleted ink is a baked PDF annotation, so its pixels live in the
        -- rendered page tile, not our overlay. Schedule a proper "ui" refresh
        -- -- like KOReader's own deleteHighlight -- so the tile is regenerated
        -- from the pruned in-memory doc and the ink disappears without a page
        -- turn.
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
        logger.info("Pencil: removed", deleted, "embedded ink annotation(s) (deferred write)")
    end

    for _, stroke in ipairs(strokes) do
        stroke.embedded = nil
        stroke.staged = nil
        stroke.annot_id = nil
    end
    return deleted
end

-- Delete tagged ink in the in-memory document, given { [pageno] = { [tag] = true } }.
-- Marks the document for the close write when anything was removed.
-- Returns the number of annotations deleted.
function Pencil:_deleteInkTagsByPage(tags_by_page)
    local doc = self.ui.document
    local deleted = 0
    for pageno, tags in pairs(tags_by_page) do
        local page
        local ok, res = pcall(function()
            page = doc._document:openPage(pageno)
            return deleteTaggedInk(page, tags)
        end)
        if page then page:close() end
        if ok then
            deleted = deleted + res
        else
            logger.warn("Pencil: deleting embedded ink failed on page", pageno, res)
        end
    end
    if deleted > 0 then
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
    end
    return deleted
end

-- Replay the deletions an earlier session queued but never wrote (it ended
-- before its close write). Only those are replayed: this session's own
-- deletions were applied when they were made. Deleting is by our own tag, so
-- replaying is harmless. Run on open, so leftover ink vanishes at once, and
-- again on close if it couldn't run then. Returns the number of annotations
-- deleted, or nil when the deletions can't be applied here (no ink support,
-- not a writable PDF), in which case the queue must be kept.
function Pencil:applyPendingInkDeletes()
    local unapplied = self._unapplied_ink_deletes
    if not (unapplied and next(unapplied)) then return 0 end
    if not self:writablePdfDoc() then return nil end
    local deleted = self:_deleteInkTagsByPage(groupTagsByPage(unapplied))
    self._unapplied_ink_deletes = nil
    if deleted > 0 then
        logger.info("Pencil: removed", deleted, "ink annotation(s) left by an earlier session")
    end
    return deleted
end

-- Remove the PDF ink of strokes erased by a gesture that hasn't reached its
-- pen-up yet (the page changed or the book is closing mid-erase), so the
-- annotation can't outlive its stroke.
function Pencil:flushPendingEraseToPdf()
    self:deleteEmbeddedAnnotationsFor(self.eraser_deleted)
    self:deleteEmbeddedAnnotationsFor(self.eraser_button_deleted)
end

-- Stage every not-yet-embedded pencil stroke as a native ink annotation. Used
-- by the "auto-save on close" option; the single disk write is flushPdfEdits()
-- right after. Each stroke is placed with the page coordinates recorded when it
-- was drawn, so this is safe for every page, not just the one on screen.
-- Strokes without recorded page coordinates are skipped and stay as overlay.
-- Text highlights are intentionally left out (KOReader keeps drawing its own
-- copy from the sidecar, which would double a baked-in /Highlight); those stay
-- on the manual per-page action. Returns the number of strokes staged.
function Pencil:autoSaveInkToPdf()
    local staged = self:stageStrokesInk(self.strokes)
    if staged > 0 then
        logger.info("Pencil: staged", staged, "stroke(s) for embedding on close")
    end
    return staged
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
-- Rasterize a thick line by stamping width×width squares along the segment.
-- Steps by ~half the pen width (via Geometry.segmentStepCount) so the squares
-- overlap without the ~width-fold per-pixel overdraw that stepping by 1px gives.
function Pencil:drawThickLine(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)

    if dist < 1 then
        -- Just draw a single point
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Inclusive 0..steps loop emits both endpoints (t=0 and t=1).
    local steps = PencilGeometry.segmentStepCount(dist, width)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    self:drawThickLine(bb, x1, y1, x2, y2, width, color)
end

-- Build a rectangle blender for translucent highlighter ink.
function Pencil:getHighlighterBlender(bb, color, alpha)
    alpha = alpha or 0xFF
    local c = (color or Blitbuffer.Color8(0xDD)):getColorRGB32()
    local r, g, b = c.r, c.g, c.b
    local k = alpha / 255
    local function mixWithWhite()
        return Blitbuffer.ColorRGB32(
            math.floor(255 - (255 - r) * k + 0.5),
            math.floor(255 - (255 - g) * k + 0.5),
            math.floor(255 - (255 - b) * k + 0.5), 0xFF)
    end
    if bb.getInverse and bb:getInverse() == 1 and bb.blendRectRGB32 then
        local over = Blitbuffer.ColorRGB32(r, g, b, alpha):invert()
        return function(x, y, w, h) bb:blendRectRGB32(x, y, w, h, over) end
    elseif bb.multiplyRectRGB then
        local mul = mixWithWhite()
        return function(x, y, w, h) bb:multiplyRectRGB(x, y, w, h, mul) end
    elseif bb.blendRectRGB32 then
        local over = Blitbuffer.ColorRGB32(r, g, b, alpha)
        return function(x, y, w, h) bb:blendRectRGB32(x, y, w, h, over) end
    end
    local opaque = mixWithWhite()
    return function(x, y, w, h) bb:paintRectRGB32(x, y, w, h, opaque) end
end

function Pencil:paintHighlighterStroke(bb, stroke, dx, dy)
    local points = stroke.points
    if not points or #points < 1 then return end
    local width = stroke.width or self.tool_settings[TOOL_HIGHLIGHTER].width or 20
    local cache = stroke.hl_cache
    if not cache or cache.n ~= #points or cache.width ~= width then
        cache = { n = #points, width = width,
            rects = PencilGeometry.strokeCoverageRects(points, width) }
        stroke.hl_cache = cache
    end
    local blend = self:getHighlighterBlender(bb, stroke.color, stroke.alpha)
    dx, dy = dx or 0, dy or 0
    for _, r in ipairs(cache.rects) do
        blend(r.x + dx, r.y + dy, r.w, r.h)
    end
end

function Pencil:drawLiveHighlighter(stroke, x1, y1, x2, y2)
    local live = self.live_highlighter
    if not live or live.stroke ~= stroke then
        live = { stroke = stroke, cov = PencilGeometry.newCoverage(),
            blend = self:getHighlighterBlender(Screen.bb, stroke.color, stroke.alpha) }
        self.live_highlighter = live
    end
    local width = stroke.width
    local stamps = PencilGeometry.segmentStamps(x1, y1, x2, y2, width)
    for i = 1, #stamps, 2 do
        local rects = PencilGeometry.coverageAddRect(
            live.cov, stamps[i], stamps[i + 1], width, width, true)
        for _, r in ipairs(rects) do live.blend(r.x, r.y, r.w, r.h) end
    end
end

-- Kept for compatibility with external callers; full strokes use coverage-aware rendering.
function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, color, alpha)
    local blend = self:getHighlighterBlender(bb, color, alpha)
    local cov = PencilGeometry.newCoverage()
    local stamps = PencilGeometry.segmentStamps(x1, y1, x2, y2, width)
    for i = 1, #stamps, 2 do
        local rects = PencilGeometry.coverageAddRect(cov, stamps[i], stamps[i + 1], width, width, true)
        for _, r in ipairs(rects) do blend(r.x, r.y, r.w, r.h) end
    end
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

-- Screen-space refresh rect (x, y, w, h) covering a set of just-deleted
-- strokes, expanded by the eraser width and clamped to the screen. Returns
-- nil when no stroke has geometry, signalling the caller to refresh fully.
function Pencil:erasedStrokesRefreshRect(strokes)
    local bbox = nil
    local max_width = 0
    for _, s in ipairs(strokes) do
        local b = PencilGeometry.computeStrokeBbox(s)
        if b then
            bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
        end
        max_width = math.max(max_width, s.width or 0)
    end
    if not bbox then return nil end
    -- Cover the eraser and the widest erased stroke, which can be wider
    -- (e.g. a highlighter), or its edges stay on the panel.
    local eraser_width = (self.tool_settings[TOOL_ERASER] and self.tool_settings[TOOL_ERASER].width) or 20
    local margin = math.max(eraser_width, math.floor(max_width / 2) + 4)
    bbox = PencilGeometry.bboxExpand(bbox, margin)
    bbox = PencilGeometry.bboxClampToScreen(bbox, Screen:getWidth(), Screen:getHeight())
    local w = bbox.x1 - bbox.x0
    local h = bbox.y1 - bbox.y0
    if w <= 0 or h <= 0 then return nil end
    return bbox.x0, bbox.y0, w, h
end

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
function Pencil:eraseAtPoint(x, y, page)
    -- Only erase strokes on the current page
    if self.input_debug_mode then
        self:writeDebugLog(string.format("ERASE: searching %d strokes at (%d, %d)",
            #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if self.input_debug_mode then
            self:writeDebugLog("ERASE: no strokes exist")
        end
        return nil
    end

    local eraser_width = self.tool_settings[TOOL_ERASER].width
    local deleted = {}
    local indices_to_remove = {}

    -- Iterate only strokes on the current page via the page index. Keeps the
    -- per-sample erase cost O(strokes-on-page) instead of O(total-strokes).
    local page_indices = self.page_strokes and self.page_strokes[page] or nil
    if page_indices then
        for _, i in ipairs(page_indices) do
            local stroke = self.strokes[i]
            if stroke then
                if self.input_debug_mode and stroke.points and #stroke.points > 0 then
                    local min_x, max_x, min_y, max_y = stroke.points[1].x, stroke.points[1].x, stroke.points[1].y, stroke.points[1].y
                    for _, pt in ipairs(stroke.points) do
                        if pt.x < min_x then min_x = pt.x end
                        if pt.x > max_x then max_x = pt.x end
                        if pt.y < min_y then min_y = pt.y end
                        if pt.y > max_y then max_y = pt.y end
                    end
                    self:writeDebugLog(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                        i, min_x, max_x, min_y, max_y, x, y, eraser_width))
                end
                if self:isPointNearStroke(x, y, stroke, eraser_width) then
                    table.insert(deleted, stroke)
                    table.insert(indices_to_remove, i)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASE: found stroke %d to delete", i))
                    end
                end
            end
        end
    end

    -- Remove strokes (in reverse order to maintain indices)
    if #indices_to_remove > 0 then
        table.sort(indices_to_remove, function(a, b) return a > b end)
        for _, idx in ipairs(indices_to_remove) do
            table.remove(self.strokes, idx)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("ERASE: deleted %d strokes", #deleted))
        end
        -- Embedded PDF ink for these strokes is removed once, at pen-up, by
        -- commitErase (each removal regenerates the page tile, which would
        -- flash the e-ink panel on every hit mid-gesture).
        return deleted
    end

    return nil
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    if tool == TOOL_HIGHLIGHTER then
        self:paintHighlighterStroke(bb, stroke, 0, 0)
        return
    end
    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
function Pencil:paintTo(bb, x, y)
    if self._capturing then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                -- Renders natively (same rotation as capture, or legacy group
                -- without rotation info — render strokes as-is).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("Pencil: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render saved strokes for current page (skipping stale ones).
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if not (stale_indices and stale_indices[idx]) then
            local stroke = self.strokes[idx]
            -- Skip strokes embedded (or staged) into the PDF: MuPDF renders the
            -- baked-in ink annotation, so drawing our overlay copy too would
            -- double it (and it wouldn't rotate correctly).
            if stroke and not (stroke.embedded or stroke.staged) then
                -- Strokes saved before page coordinates were recorded get
                -- them now, under the same transform the overlay is drawn
                -- with. Tried once per session so a stroke that can't be
                -- mapped doesn't cost a transform on every repaint.
                if stroke.page_points == nil and not stroke._page_points_tried
                        and not self:isReflowed() then
                    stroke._page_points_tried = true
                    self:capturePagePoints(stroke)
                end
                self:renderStroke(bb, stroke)
            end
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
end

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Store the plugin-owned strokes file path in the document metadata.
function Pencil:rememberStrokesFilePath(filepath)
    local settings = self.ui and self.ui.doc_settings
    if settings and filepath then
        settings:saveSetting(STROKES_PATH_SETTING, filepath)
    end
end

-- Recover pencil_strokes.lua after KOReader moves metadata.lua to a new
-- sidecar following a document rename. Both paths are assumed to be on the
-- same filesystem, so os.rename provides an atomic move.
function Pencil:migrateStrokesFileIfNeeded()
    local current = self:getStrokesFilePath()
    local settings = self.ui and self.ui.doc_settings
    if not current or not settings then return current end

    if lfs.attributes(current, "mode") == "file" then
        self:rememberStrokesFilePath(current)
        return current
    end

    local previous = settings:readSetting(STROKES_PATH_SETTING)
    if type(previous) ~= "string" or previous == "" or previous == current
            or lfs.attributes(previous, "mode") ~= "file" then
        return current
    end

    local old_sidecar = previous:match("^(.*)/[^/]+$")
    local moved, err = os.rename(previous, current)
    if not moved then
        logger.warn("Pencil: failed to move strokes file from", previous,
            "to", current, "error:", err)
        return current
    end

    self:rememberStrokesFilePath(current)
    logger.info("Pencil: moved strokes file from", previous, "to", current)

    -- Bring the annotation preview pictures along. Groups store each
    -- picture's filename relative to pencil_images/, so moving the folder is
    -- enough. Never overwrite pictures already in the new sidecar.
    local new_images = self:getImagesDir()
    if old_sidecar and new_images then
        local old_images = old_sidecar .. "/pencil_images"
        if lfs.attributes(old_images, "mode") == "directory"
                and not lfs.attributes(new_images, "mode") then
            local moved_images, images_err = os.rename(old_images, new_images)
            if moved_images then
                logger.info("Pencil: moved annotation images to", new_images)
            else
                logger.warn("Pencil: failed to move annotation images from", old_images,
                    "to", new_images, "error:", images_err)
            end
        end
    end

    -- rmdir only succeeds when the legacy sidecar is empty. If KOReader or
    -- another plugin left data there, it is preserved without extra handling.
    if old_sidecar then
        local removed = lfs.rmdir(old_sidecar)
        if removed then
            logger.info("Pencil: removed empty legacy sidecar", old_sidecar)
        end
    end

    return current
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:migrateStrokesFileIfNeeded()
    logger.info("Pencil: loadStrokes - filepath =", filepath)
    local was_too_new = self.strokes_file_too_new
    self.strokes_file_too_new = false

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("Pencil: strokes file does not exist yet:", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and type(data) == "table" and type(data.version) == "number"
            and data.version > STROKES_FILE_VERSION then
        -- Written by a newer Pencil, in a format this one may not read
        -- correctly. Loading it could drop what we don't understand, and the
        -- next save would write that loss to disk, so leave the file alone.
        logger.warn("Pencil: strokes file is version", data.version,
            "but this Pencil writes version", STROKES_FILE_VERSION, "- not loading or saving it")
        self.strokes = {}
        self.page_strokes = {}
        self.annotation_groups = {}
        self.strokes_file_too_new = true
        if not was_too_new then
            UIManager:nextTick(function()
                UIManager:show(InfoMessage:new{
                    text = _("This book's ink was saved by a newer version of Pencil. Update Pencil to see it.\n\nUntil then, Pencil won't save ink for this book, so the newer ink stays safe."),
                })
            end)
        end
        return
    end
    if ok and data and data.strokes then
        -- { [tag] = page }: PDF ink deletions a session queued but didn't
        -- write. All of them are still unapplied in this session's document.
        self.pending_ink_deletes = {}
        self._unapplied_ink_deletes = {}
        if type(data.pending_ink_deletes) == "table" then
            for tag, page in pairs(data.pending_ink_deletes) do
                if type(tag) == "string" and type(page) == "number" then
                    self.pending_ink_deletes[tag] = page
                    self._unapplied_ink_deletes[tag] = page
                end
            end
        end
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = self:strokeFromSaved(saved)
        end
        self:rebuildPageIndex()

        -- Load annotation groups or bootstrap from v1 data
        if data.annotation_groups and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        self:rememberStrokesFilePath(filepath)
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("Pencil: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
        self.annotation_groups = {}
    end
end

-- Sidecar form of stroke.page_points: a packed string, false for a stroke
-- drawn while reflowed (never to be mapped, see recordPagePoints), or nil.
-- page_points never change once recorded, so the packed string is kept on
-- the stroke (_pp_packed) rather than rebuilt on every save.
local function packPagePoints(stroke)
    local points = stroke.page_points
    if points == false then return false end
    if not (points and #points > 0) then return nil end
    stroke._pp_packed = stroke._pp_packed or PencilGeometry.packPoints(points)
    return stroke._pp_packed
end

local function unpackPagePoints(pp)
    if pp == false then return false end
    if type(pp) == "string" and pp ~= "" then return PencilGeometry.unpackPoints(pp) end
    return nil
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        -- v4: points packed as a single "x y x y ..." string instead of an
        -- array of {x=,y=} tables, so the serializer doesn't walk every point.
        p = PencilGeometry.packPoints(stroke.points),
        color_name = stroke.color_name,  -- Save color name for persistence
        transcription = stroke.transcription,
        transcription_group_id = stroke.transcription_group_id,
        transcription_language = stroke.transcription_language,
        transcription_datetime = stroke.transcription_datetime,
        transcription_engine = stroke.transcription_engine,
        -- PDF export: points in native page coordinates (packed like `p`) and
        -- the zoom they were drawn at, so embedding doesn't depend on the
        -- page on screen at close. `embedded` is only set once the ink has
        -- actually been written to the file (never while merely staged).
        pp = packPagePoints(stroke),
        pz = stroke.page_zoom,
        embedded = stroke.embedded,
        annot_id = stroke.annot_id,      -- tag of its PDF annotation (for the eraser)
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        color = self:findColorByName(saved.color_name) or color
    end

    -- Legacy highlighter strokes had no selectable color; preserve their appearance.
    local alpha = saved.alpha or tool_settings.alpha
    -- ("Highlight" is what early tool box builds called that same gray.)
    if tool == TOOL_HIGHLIGHTER and (not saved.color_name or saved.color_name == "Highlight") then
        color = Blitbuffer.Color8(0xDD)
        alpha = 0xFF
    end
    -- Points: v4 stores a packed "x y ..." string in `p`; v3 and earlier store
    -- an array of {x=,y=} tables in `points`. Reconstruct the in-memory
    -- {x=,y=} array either way.
    local points
    if saved.p ~= nil then
        points = PencilGeometry.unpackPoints(saved.p)
    else
        points = saved.points or {}
    end

    return {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = alpha,
        datetime = saved.datetime,
        points = saved.points,
        transcription = saved.transcription,
        transcription_group_id = saved.transcription_group_id,
        transcription_language = saved.transcription_language,
        transcription_datetime = saved.transcription_datetime,
        transcription_engine = saved.transcription_engine,
        points = points,
        page_points = unpackPagePoints(saved.pp),
        _pp_packed = type(saved.pp) == "string" and saved.pp ~= "" and saved.pp or nil,
        page_zoom = saved.pz,
        embedded = saved.embedded,
        annot_id = saved.annot_id,
    }
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Never overwrite a file from a newer Pencil (see loadStrokes).
    if self.strokes_file_too_new then
        logger.warn("Pencil: not saving - strokes file is from a newer Pencil:", filepath)
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- No ink and no file yet: nothing to save, so don't give every book
    -- that's merely opened an empty strokes file.
    if #self.strokes == 0 and not lfs.attributes(filepath, "mode") then
        return
    end

    -- A book being written in for the first time may not have its sidecar
    -- folder yet: KOReader only creates it when it saves its own settings,
    -- usually on close. Create it, or the ink isn't on disk until then.
    local sidecar_dir = filepath:match("^(.*)/[^/]+$")
    if sidecar_dir and lfs.attributes(sidecar_dir, "mode") ~= "directory" then
        local ok, err = require("util").makePath(sidecar_dir)
        if not ok then
            logger.err("Pencil: failed to create sidecar folder:", sidecar_dir, "error:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 5 keeps v4 packed points and adds optional
    -- MyScript transcription metadata to strokes and annotation groups. Version 4
    -- "x y x y ..." string (field `p`) instead of an array of {x=,y=} tables,
    -- cutting serialize time + file size on heavily-annotated documents. v3 and
    -- earlier (points array) still load via strokeFromSaved's fallback.
    local data = {
        version = STROKES_FILE_VERSION,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
        -- PDF ink deleted in memory but not yet written to the file.
        pending_ink_deletes = (self.pending_ink_deletes and next(self.pending_ink_deletes))
            and self.pending_ink_deletes or nil,
    }

    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        self:rememberStrokesFilePath(filepath)
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("Pencil: failed to open file for writing:", filepath, "error:", err)
    end
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    self:closeToolBox()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        self:commitStroke(self.current_stroke)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- An erase gesture still in progress never reaches its pen-up handler.
    self:flushPendingEraseToPdf()
    -- Make sure every queued ink deletion is in the document for the write.
    local pok, pres = pcall(self.applyPendingInkDeletes, self)
    if not pok then logger.err("Pencil: applyPendingInkDeletes error:", pres) end
    local deletes_applied = pok and pres ~= nil

    -- Auto-save pencil ink into the PDF file (opt-in). This only stages the
    -- annotations in memory; the actual disk write is the single flushPdfEdits()
    -- below. Must run while the document is still open/writable.
    if self.auto_save_pdf then
        local ok, err = pcall(function() self:autoSaveInkToPdf() end)
        if not ok then
            logger.err("Pencil: autoSaveInkToPdf error:", err)
        end
    end

    -- Single, final write of any in-memory PDF edits the plugin made this
    -- session (auto-saved ink, erased ink, manual per-page saves). One
    -- incremental write, then is_edited is cleared so KOReader's own close
    -- doesn't stack a second write (which corrupts the xref). Runs regardless
    -- of the auto-save toggle, since the eraser/manual paths also set dirty.
    local ok, ferr = pcall(function() self:flushPdfEdits() end)
    if not ok then logger.err("Pencil: flushPdfEdits error:", ferr) end
    -- flushPdfEdits clears _pdf_dirty only on a successful write. Only then do
    -- strokes staged this session (by auto-save or the manual action) become
    -- `embedded`; otherwise they're un-staged so the sidecar never claims ink
    -- the file didn't receive, and the next close retries them.
    self:settleStagedStrokes(not self._pdf_dirty)
    -- Likewise the queued deletions are done once the file has them (or
    -- nothing needed writing); otherwise they stay queued for next time.
    if deletes_applied and not self._pdf_dirty then
        self.pending_ink_deletes = {}
        self._unapplied_ink_deletes = nil
    end

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_deleted = nil
    self.undo_stack = {}

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep. The debounced save only runs once writing
    -- pauses, so ink from the last moments before sleep may not be on disk.
    self:flushDeferredWork()
    self:flushPendingCaptures()
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if #self.strokes == 0 then
        self:loadStrokes()
    end
    logger.info("Pencil: after loadStrokes, strokes count =", #self.strokes,
        "groups =", #self.annotation_groups)

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Finish PDF ink deletions an earlier session didn't get to write.
    local pok, perr = pcall(self.applyPendingInkDeletes, self)
    if not pok then logger.err("Pencil: applyPendingInkDeletes error:", perr) end

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    -- The page is redrawn in full, so the region the last strokes touched no
    -- longer needs its own refresh; don't let it widen the next page's.
    self.pending_refresh_bbox = nil
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        -- The view has already moved, so the live transform no longer matches
        -- where the stroke was drawn: its page coordinates are recorded when
        -- its page is next painted instead.
        self:commitStroke(self.current_stroke, true)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self:flushPendingEraseToPdf()
    self.eraser_deleted = nil
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        -- The view has already moved, so the live transform no longer matches
        -- where the stroke was drawn: its page coordinates are recorded when
        -- its page is next painted instead.
        self:commitStroke(self.current_stroke, true)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self:flushPendingEraseToPdf()
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
