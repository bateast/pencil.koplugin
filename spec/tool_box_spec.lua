--[[--
Integration tests for the quick tool box wiring in the real main.lua: tool
state and "previous tool", presets, settings round-trip and validation, the
hold-still trigger, opening and closing the box, legacy highlighter strokes,
and a guard that the drawing hot path never touches the tool box code.

KOReader modules are stubbed, as in overlay_spec; Pencil:init runs for real.

Run with: busted spec/tool_box_spec.lua
--]]--

package.path = "pencil.koplugin/?.lua;" .. package.path

local function permissive()
    return setmetatable({}, {
        __index = function() return permissive() end,
        __call = function() return permissive() end,
    })
end

------------------------------------------------------------------------------
-- Fakes the tests observe
------------------------------------------------------------------------------

local store            -- G_reader_settings backing table
local UIManager, notified, clock
local refreshes        -- Screen:refreshUI calls
local painted          -- Screen.bb:paintRectRGB32 calls

local function color(v) return { v = v } end

-- main.lua requires many KOReader modules; any that is not one of the plugin's
-- own files and not stubbed below resolves to a permissive stub, so this spec
-- runs on its own and does not depend on other specs having registered them.
local searchers = package.searchers or package.loaders
local fallback_searcher
local function install_fallback_searcher()
    if fallback_searcher then return end
    fallback_searcher = function(name)
        if name:match("^lib/") or name == "geometry" or name == "toolset" or name == "toolbox" then
            return nil
        end
        return function() return permissive() end
    end
    searchers[#searchers + 1] = fallback_searcher
end
local function remove_fallback_searcher()
    for i = #searchers, 1, -1 do
        if searchers[i] == fallback_searcher then table.remove(searchers, i) end
    end
    fallback_searcher = nil
end

local function loadPencil()
    install_fallback_searcher()
    local stubbed = {
        "ui/widget/container/centercontainer", "datastorage",
        "ui/widget/container/framecontainer", "ui/geometry", "ui/gesturerange",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/size",
        "ui/widget/container/widgetcontainer", "libs/libkoreader-lfs", "ffi/util",
        "dispatcher",
    }
    for _, name in ipairs(stubbed) do package.loaded[name] = permissive() end

    local function rgb(c) return function() return c end end
    package.loaded["ffi/blitbuffer"] = {
        Color8 = function(v) local c = { v = v, r = v, g = v, b = v }; c.getColorRGB32 = rgb(c); return c end,
        ColorRGB32 = function(r, g, b)
            local c = { r = r, g = g, b = b }; c.getColorRGB32 = rgb(c); return c
        end,
        COLOR_BLACK = color(0),
        COLOR_WHITE = color(255),
    }

    local screen = {
        bb = { paintRectRGB32 = function(_, ...) painted[#painted + 1] = { ... } end },
        night_mode = false,
        getWidth = function() return 1264 end,
        getHeight = function() return 1680 end,
        getRotationMode = function() return 0 end,
        refreshUI = function(_, x, y, w, h) refreshes[#refreshes + 1] = { x = x, y = y, w = w, h = h } end,
        refreshFast = function() end,
        scaleBySize = function(_, n) return n end,
    }
    package.loaded["device"] = setmetatable({
        screen = screen,
        isTouchDevice = function() return true end,
        isEmulator = function() return false end,
    }, { __index = function() return permissive() end })

    package.loaded["ui/time"] = {
        now = function() return clock end,
        to_ms = function(t) return t end,
    }
    package.loaded["ui/widget/container/inputcontainer"] = {
        extend = function(_, class) return class end,
    }
    package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a end }
    package.loaded["ui/widget/notification"] = {
        SOURCE_DISPATCHER = 0x0020, SOURCE_ALWAYS_SHOW = 0x8000,
        notify = function(_, text, source) notified[#notified + 1] = { text = text, source = source } end,
    }
    package.loaded["ui/uimanager"] = UIManager
    package.loaded["logger"] = {
        dbg = function() end, info = function() end, warn = function() end, err = function() end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    package.loaded["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }
    package.loaded["lib/toolset"] = nil
    package.loaded["main"] = nil
    return dofile("pencil.koplugin/main.lua"), screen
end

local Pencil, Screen

local function fresh_globals()
    store = {}
    notified, refreshes, painted, clock = {}, {}, {}, 1000
    UIManager = {
        _window_stack = {}, shown = {}, closed = {}, dirty = {},
        show = function(self, w, mode, region) self.shown[#self.shown + 1] = { w = w, mode = mode, region = region } end,
        close = function(self, w) self.closed[#self.closed + 1] = w end,
        setDirty = function(self, w, mode, region) self.dirty[#self.dirty + 1] = { w = w, mode = mode, region = region } end,
        scheduled = 0,
        scheduleIn = function(self) self.scheduled = self.scheduled + 1 end,
        unschedule = function() end,
    }
    -- main.lua runs in the real global table, not busted's per-test sandbox
    local REAL_G = (getfenv and getfenv(0)) or _G
    REAL_G.G_reader_settings = {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
    }
end

-- A Pencil built by the real init() against a fake ReaderUI.
local function new_pencil()
    local ui = {
        active_widgets = {},
        menu = { registerToMainMenu = function() end },
        view = { registerViewModule = function() end, paintTo = function() end },
        doc_settings = {},   -- no sidecar yet: strokes aren't loaded
        registerTouchZones = function() end,
        unRegisterTouchZones = function() end,
    }
    local p = setmetatable({ ui = ui }, { __index = Pencil })
    Pencil.init(p)
    p.paintTo = function() end            -- the page repaint isn't under test
    p.getCurrentPage = function() return 1 end
    return p
end

local function reset_class_state()
    -- tool_settings is a class-level table: give every test its own copy
    Pencil.tool_settings = {
        pen = { width = 3, color = nil, color_name = "Black", alpha = 255 },
        highlighter = { width = 20, color = nil, color_name = "Gray", alpha = 166 },
        eraser = { width = 20 },
    }
end

describe("quick tool box wiring", function()
    before_each(function()
        fresh_globals()
        Pencil, Screen = loadPencil()
        reset_class_state()
    end)

    after_each(function()
        remove_fallback_searcher()
    end)

    describe("defaults", function()
        it("offers the marker the main palette without black, defaulting to Gray", function()
            local p = new_pencil()
            assert.equals(#p.available_colors - 1, #p.highlight_colors)
            for _, info in ipairs(p.highlight_colors) do assert.is_not.equals("Black", info.name) end
            assert.same(p:getHighlighterColors(), p.highlight_colors)
            assert.equals("Gray", p.tool_settings.highlighter.color_name)
        end)

        it("starts with a full row of valid presets and the hold-still trigger off", function()
            local p = new_pencil()
            assert.equals(6, #p.tool_presets)
            assert.is_false(p.tool_box_hold)
            assert.equals("pen", p.current_tool)
        end)

        it("every default preset uses a color that exists", function()
            local p = new_pencil()
            for _, preset in ipairs(p.tool_presets) do
                assert.is_truthy(p:findColor(preset.tool, preset.color_name),
                    preset.tool .. "/" .. preset.color_name)
            end
        end)
    end)

    describe("tool state and the previous tool", function()
        it("remembers the tool it left, and swaps back and forth", function()
            local p = new_pencil()
            p:switchTool({ tool = "highlighter" })
            assert.equals("highlighter", p.current_tool)
            assert.equals("pen", p.prev_tool_state.tool)

            p:onPencilSwapTool()
            assert.equals("pen", p.current_tool)
            p:onPencilSwapTool()
            assert.equals("highlighter", p.current_tool)
        end)

        it("swap restores the color and width of that tool, not just its kind", function()
            local p = new_pencil()
            p:switchTool({ tool = "pen", color_name = "Red", width = 7 })   -- red pen, 7
            p:switchTool({ tool = "pen", color_name = "Blue", width = 3 })  -- then blue, 3
            p:onPencilSwapTool()
            assert.equals("Red", p.tool_settings.pen.color_name)
            assert.equals(7, p.tool_settings.pen.width)
            p:onPencilSwapTool()
            assert.equals("Blue", p.tool_settings.pen.color_name)
        end)

        it("says so when there is no previous tool yet", function()
            local p = new_pencil()
            p:onPencilSwapTool()
            assert.equals("No previous tool yet", notified[1].text)
            assert.equals("pen", p.current_tool)
        end)

        it("re-picking the tool in hand does not wipe the previous one", function()
            local p = new_pencil()
            p:switchTool({ tool = "highlighter" })
            p:switchTool({ tool = "highlighter" })
            assert.equals("pen", p.prev_tool_state.tool)
        end)

        it("toggling the eraser returns to the highlighter, not always the pen", function()
            local p = new_pencil()
            p:switchTool({ tool = "highlighter" })
            p:togglePenEraser()
            assert.equals("eraser", p.current_tool)
            p:togglePenEraser()
            assert.equals("highlighter", p.current_tool)
        end)

        it("toggling the eraser from the pen still returns to the pen", function()
            local p = new_pencil()
            p:togglePenEraser()
            p:togglePenEraser()
            assert.equals("pen", p.current_tool)
        end)

        it("the gesture toggle follows the reader's notification settings", function()
            local p = new_pencil()
            p:onPencilToggleTool()
            assert.equals(0x0020, notified[1].source)
            assert.equals("Tool: eraser", notified[1].text)
        end)

        it("names the highlighter in its toast", function()
            local p = new_pencil()
            p:onPencilSelectHighlighter()
            assert.equals("highlighter", p.current_tool)
            assert.equals("Tool: highlighter", notified[1].text)
        end)

        it("ignores a width or color that is invalid", function()
            local p = new_pencil()
            p:applyToolState({ tool = "pen", color_name = "Chartreuse", width = 99999 })
            assert.equals("Black", p.tool_settings.pen.color_name)
            assert.equals(3, p.tool_settings.pen.width)
        end)
    end)

    describe("provider (what the box calls)", function()
        it("selecting a preset sets tool, color and width and remembers the old tool", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.selectPreset(6)   -- default 6: Yellow marker, 20
            assert.equals("highlighter", p.current_tool)
            assert.equals("Yellow", p.tool_settings.highlighter.color_name)
            assert.equals(20, p.tool_settings.highlighter.width)
            assert.equals("pen", p.prev_tool_state.tool)
        end)

        it("setColor and setWidth change the tool in hand and are saved", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setColor("Red"); prov.setWidth(9)
            assert.equals("Red", p.tool_settings.pen.color_name)
            assert.equals(9, p.tool_settings.pen.width)
            assert.equals("Red", store.pencil_annotation_settings.pen_color_name)
            assert.equals(9, store.pencil_annotation_settings.pen_width)
        end)

        it("setColor and setWidth do nothing to the eraser", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setTool("eraser")
            prov.setColor("Red"); prov.setWidth(9)
            assert.equals("Black", p.tool_settings.pen.color_name)
            assert.equals(3, p.tool_settings.pen.width)
        end)

        it("marker color changes the highlighter, not the pen", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setTool("highlighter")
            prov.setColor("Cyan")
            assert.equals("Cyan", p.tool_settings.highlighter.color_name)
            assert.equals("Black", p.tool_settings.pen.color_name)
        end)

        it("rejects black for the marker (not in the marker palette)", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setTool("highlighter")
            prov.setColor("Black")
            assert.equals("Gray", p.tool_settings.highlighter.color_name)
        end)

        it("eraser size changes how far it reaches", function()
            local p = new_pencil()
            p:makeToolBoxProvider().setEraserWidth(40)
            assert.equals(40, p.tool_settings.eraser.width)
            p:makeToolBoxProvider().setEraserWidth(-5)
            assert.equals(40, p.tool_settings.eraser.width)
        end)

        it("saving a preset stores the tool in hand in that slot and persists it", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setColor("Blue"); prov.setWidth(9)
            prov.savePreset(2)
            assert.same({ tool = "pen", color_name = "Blue", width = 9 }, p.tool_presets[2])
            assert.equals("Blue", store.pencil_annotation_settings.tool_presets[2].color_name)
        end)

        it("the eraser cannot be saved as a preset", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setTool("eraser")
            local before = #p.tool_presets
            prov.savePreset(1)
            prov.savePreset(before + 1)
            assert.equals(before, #p.tool_presets)
            assert.equals("pen", p.tool_presets[1].tool)
        end)

        it("canUndo follows the undo stack", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            assert.is_false(prov.canUndo())
            p.undo_stack = { { type = "add" } }
            assert.is_true(prov.canUndo())
        end)
    end)

    describe("settings", function()
        it("round-trips presets, marker color and width, and eraser size", function()
            local p = new_pencil()
            local prov = p:makeToolBoxProvider()
            prov.setTool("highlighter"); prov.setColor("Orange"); prov.setWidth(30)
            prov.setEraserWidth(40)
            prov.setTool("pen"); prov.setColor("Red"); prov.setWidth(7)
            prov.savePreset(1)
            p.tool_box_hold = true
            p:saveSettings()

            reset_class_state()
            local q = new_pencil()
            assert.is_true(q.tool_box_hold)
            assert.equals("Orange", q.tool_settings.highlighter.color_name)
            assert.equals(30, q.tool_settings.highlighter.width)
            assert.equals(40, q.tool_settings.eraser.width)
            assert.equals("Red", q.tool_settings.pen.color_name)
            assert.equals(7, q.tool_settings.pen.width)
            assert.same({ tool = "pen", color_name = "Red", width = 7 }, q.tool_presets[1])
            assert.equals("pen", q.current_tool)   -- always starts on the pen
        end)

        it("survives a malformed settings file", function()
            store.pencil_annotation_settings = {
                tool_presets = { { tool = "laser", color_name = 5, width = "x" }, "junk", 7 },
                highlighter_color_name = "Chartreuse",
                highlighter_width = 12345,
                eraser_width = -1,
                pen_width = 2.5,
                pen_color_name = "Black",
            }
            local p = new_pencil()
            assert.equals(6, #p.tool_presets)                       -- defaults
            assert.equals("Gray", p.tool_settings.highlighter.color_name)
            assert.is_truthy(p.tool_settings.highlighter.color)     -- not left without a color
            assert.equals(20, p.tool_settings.highlighter.width)
            assert.equals(20, p.tool_settings.eraser.width)
            assert.equals(3, p.tool_settings.pen.width)
        end)

        it("accepts a saved pen width outside the picker's four (a preset can set it)", function()
            store.pencil_annotation_settings = { pen_width = 12 }
            assert.equals(12, new_pencil().tool_settings.pen.width)
        end)

        it("renames the early 'Highlight' marker preset to Gray instead of dropping it", function()
            store.pencil_annotation_settings = {
                tool_presets = { { tool = "highlighter", color_name = "Highlight", width = 30 },
                                 { tool = "pen", color_name = "Red", width = 5 } },
            }
            local p = new_pencil()
            assert.same({ tool = "highlighter", color_name = "Gray", width = 30 }, p.tool_presets[1])
            assert.equals(2, #p.tool_presets)
        end)

        it("keeps the old settings file format working", function()
            store.pencil_annotation_settings = {
                pen_color_name = "Red", pen_width = 5, experimental_color_picker = true,
            }
            local p = new_pencil()
            assert.equals("Red", p.tool_settings.pen.color_name)
            assert.is_true(p.experimental_color_picker)
            assert.equals(6, #p.tool_presets)
            assert.is_false(p.tool_box_hold)
        end)
    end)

    describe("highlighter strokes saved earlier", function()
        it("a stroke saved without a color name stays light gray after the marker is recolored", function()
            local p = new_pencil()
            p:makeToolBoxProvider().setTool("highlighter")
            p:makeToolBoxProvider().setColor("Cyan")
            local s = p:strokeFromSaved{ page = 1, tool = "highlighter", width = 20, p = "1 1 5 5" }
            assert.equals(0xDD, s.color.v)
        end)

        it("a named marker color loads as that color", function()
            local p = new_pencil()
            local s = p:strokeFromSaved{ page = 1, tool = "highlighter", width = 20, color_name = "Orange", p = "1 1 5 5" }
            assert.same(p:findColor("highlighter", "Orange"), s.color)
        end)

        it("the early 'Highlight' name loads as the same opaque light gray", function()
            local p = new_pencil()
            local s = p:strokeFromSaved{ page = 1, tool = "highlighter", width = 20, color_name = "Highlight", p = "1 1" }
            assert.equals(0xDD, s.color.v)
            assert.equals(0xFF, s.alpha)
        end)

        it("a stroke saved with no color name also stays opaque light gray", function()
            local p = new_pencil()
            p:makeToolBoxProvider().setTool("highlighter")
            p:makeToolBoxProvider().setColor("Cyan")
            local s = p:strokeFromSaved{ page = 1, tool = "highlighter", width = 20, p = "1 1" }
            assert.equals(0xDD, s.color.v)
            assert.equals(0xFF, s.alpha)
        end)

        it("pen strokes load as before", function()
            local p = new_pencil()
            local s = p:strokeFromSaved{ page = 1, tool = "pen", width = 5, color_name = "Red", p = "1 1 5 5" }
            assert.same(p:findColor("pen", "Red"), s.color)
            assert.equals(5, s.width)
        end)
    end)

    describe("opening the box", function()
        local FakeBox, boxes

        before_each(function()
            boxes = {}
            FakeBox = {
                new = function(_, o)
                    o.dimen = { x = 10, y = 10, w = 400, h = 200 }
                    o.close = function(self)
                        UIManager:close(self)
                        if self.on_close then self.on_close() end
                    end
                    boxes[#boxes + 1] = o
                    return o
                end,
            }
            package.loaded["lib/toolbox"] = FakeBox
        end)

        it("shows the box once and marks the picker as showing", function()
            local p = new_pencil()
            p:showToolBox(600, 900)
            p:showToolBox(600, 900)
            assert.equals(1, #boxes)
            assert.equals(1, #UIManager.shown)
            assert.is_true(p.color_picker_showing)
            assert.equals(600, boxes[1].anchor_x)
        end)

        it("passes a provider that talks to this plugin", function()
            local p = new_pencil()
            p:showToolBox()
            boxes[1].provider.setTool("highlighter")
            assert.equals("highlighter", p.current_tool)
        end)

        it("clears its state when the box closes, so it can open again", function()
            local p = new_pencil()
            p:showToolBox()
            boxes[1]:close()
            assert.is_nil(p.tool_box_widget)
            assert.is_false(p.color_picker_showing)
            p:showToolBox()
            assert.equals(2, #boxes)
        end)

        it("closeToolBox closes an open box and is harmless without one", function()
            local p = new_pencil()
            p:closeToolBox()
            p:showToolBox()
            p:closeToolBox()
            assert.equals(1, #UIManager.closed)
        end)

        it("closes when the document closes or the plugin is toggled off", function()
            local p = new_pencil()
            p.strokes = {}
            p.saveStrokes = function() end
            p.flushPendingCaptures = function() end
            p.syncAllBookmarks = function() end
            p.teardownPenInput = function() end
            p:showToolBox()
            p:onCloseDocument()
            assert.is_nil(p.tool_box_widget)
        end)

        it("drops the dot a held-still pen made, and refreshes only that dot", function()
            local p = new_pencil()
            p.current_stroke = { page = 1, tool = "pen", width = 5, points = { { x = 600, y = 900 } } }
            p:showToolBox(600, 900)
            assert.is_nil(p.current_stroke)
            assert.equals(1, #refreshes)
            local r = refreshes[1]
            assert.is_true(r.w < 100 and r.h < 100, "refreshed " .. r.w .. "x" .. r.h .. ", not the whole screen")
            assert.is_true(r.x <= 600 and r.x + r.w >= 600)
        end)

        it("survives a box that fails to load, telling the user and leaving the pen alone", function()
            package.loaded["lib/toolbox"] = nil
            package.preload["lib/toolbox"] = function() error("boom") end
            package.preload["toolbox"] = function() error("boom") end
            local p = new_pencil()
            p:showToolBox()
            assert.is_nil(p.tool_box_widget)
            assert.is_false(p.color_picker_showing)
            assert.equals("The tool box could not be loaded.", notified[1].text)
            package.preload["lib/toolbox"], package.preload["toolbox"] = nil, nil
        end)

        it("the gesture action refuses politely while Pencil is off", function()
            local p = new_pencil()
            p:onPencilOpenToolBox()
            assert.equals(0, #boxes)
            assert.equals("Enable Pencil first", notified[1].text)
            store.pencil_annotation_enabled = true
            p:onPencilOpenToolBox()
            assert.equals(1, #boxes)
        end)
    end)

    describe("hold-still trigger", function()
        local boxes

        before_each(function()
            boxes = {}
            package.loaded["lib/toolbox"] = { new = function(_, o)
                o.dimen = { x = 0, y = 0, w = 1, h = 1 }
                o.close = function() end
                boxes[#boxes + 1] = o
                return o
            end }
        end)

        local function holding(p, ms)
            p.pen_down = true
            p.pen_x, p.pen_y = 300, 400
            p.color_picker_start_time = clock - ms
        end

        it("opens the box after the hold delay when enabled", function()
            local p = new_pencil()
            p.tool_box_hold = true
            holding(p, 600)
            p:checkColorPickerTrigger()
            assert.equals(1, #boxes)
            assert.equals(300, boxes[1].anchor_x)
            assert.equals(400, boxes[1].anchor_y)
        end)

        it("waits for the full delay", function()
            local p = new_pencil()
            p.tool_box_hold = true
            holding(p, 200)
            p:checkColorPickerTrigger()
            assert.equals(0, #boxes)
        end)

        it("does nothing at all when every picker is off (the default)", function()
            local p = new_pencil()
            holding(p, 5000)
            p:checkColorPickerTrigger()
            assert.equals(0, #boxes)
            assert.equals(0, #UIManager.shown)
        end)

        it("does not open a second box while one is showing", function()
            local p = new_pencil()
            p.tool_box_hold = true
            holding(p, 600); p:checkColorPickerTrigger()
            holding(p, 600); p:checkColorPickerTrigger()
            assert.equals(1, #boxes)
        end)

        it("takes the place of the experimental color picker when both are on", function()
            local p = new_pencil()
            p.tool_box_hold = true
            p.experimental_color_picker = true
            local old_picker_shown = false
            p.showColorPicker = function() old_picker_shown = true end
            holding(p, 600)
            p:checkColorPickerTrigger()
            assert.equals(1, #boxes)
            assert.is_false(old_picker_shown)
        end)

        it("the highlighter's own picker still gets its tool (not the pen picker)", function()
            local p = new_pencil()
            p.experimental_color_picker = true
            p.color_picker_tool = "highlighter"
            local got
            p.showColorPicker = function(_, x, y, tool) got = { x = x, y = y, tool = tool } end
            holding(p, 600)
            p:checkColorPickerTrigger()
            assert.same({ x = 300, y = 400, tool = "highlighter" }, got)
            assert.equals(0, #boxes)
        end)

        it("a text highlight in progress keeps the highlighter picker, not the tool box", function()
            local p = new_pencil()
            p.tool_box_hold = true
            p.highlighting = true
            p:beginPickerTracking(300, 400, "highlighter")
            assert.is_nil(p.color_picker_start_time)        -- nothing tracked, nothing scheduled
            p.experimental_color_picker = true
            local picked
            p.showColorPicker = function(_, _, _, tool) picked = tool end
            p:beginPickerTracking(300, 400, "highlighter")
            p.pen_x, p.pen_y, p.pen_down = 300, 400, true
            p.color_picker_start_time = clock - 600
            p:checkColorPickerTrigger()
            assert.equals("highlighter", picked)
            assert.equals(0, #boxes)
        end)

        it("pen-down tracking starts for any drawing tool once the trigger is on", function()
            local p = new_pencil()
            p.tool_box_hold = true
            for _, tool in ipairs({ "pen", "highlighter" }) do
                p:resetColorPickerTracking()
                p:beginPickerTracking(10, 20, tool)
                assert.is_truthy(p.color_picker_start_time, tool)
            end
        end)

        it("leaves the old color picker alone when the tool box trigger is off", function()
            local p = new_pencil()
            p.experimental_color_picker = true
            local old_picker_shown = false
            p.showColorPicker = function() old_picker_shown = true end
            holding(p, 600)
            p:checkColorPickerTrigger()
            assert.is_true(old_picker_shown)
            assert.equals(0, #boxes)
        end)
    end)

    describe("the drawing hot path", function()
        -- The pen must never lag: while drawing, none of the tool box code may run.
        local function body_of(source, name)
            local start = source:find("\nfunction Pencil:" .. name .. "%(")
            assert.is_truthy(start, name .. " not found")
            local stop = source:find("\nend\n", start, true)
            return source:sub(start, stop + 4)
        end

        local source
        before_each(function()
            local f = assert(io.open("pencil.koplugin/main.lua", "r"))
            source = f:read("*a")
            f:close()
        end)

        it("stylus handling, stroke start/extend/end and rasterizing don't mention the tool box", function()
            for _, name in ipairs({ "routeStylusSlot", "handleStylusSlot", "startRawStroke",
                    "addRawPoint", "endRawStroke", "drawThickLine", "drawLineSegment",
                    "drawHighlighterSegment", "renderStroke", "paintHighlighterStroke",
                    "drawLiveHighlighter", "getHighlighterBlender" }) do
                local body = body_of(source, name)
                assert.is_nil(body:find("Toolset"), name .. " calls Toolset")
                assert.is_nil(body:find("ToolBox"), name .. " touches the tool box")
                assert.is_nil(body:find("tool_presets"), name .. " reads presets")
                assert.is_nil(body:find("makeToolBoxProvider"), name .. " builds a provider")
            end
        end)

        it("drawing a whole stroke runs no tool set logic and shows no widget", function()
            local p = new_pencil()
            local Toolset = require("lib/toolset")
            local calls = 0
            for name, fn in pairs(Toolset) do
                if type(fn) == "function" then
                    Toolset[name] = function(...) calls = calls + 1; return fn(...) end
                end
            end

            p:startRawStroke()
            for i = 1, 300 do p:addRawPoint(100 + i * 2, 200 + (i % 17)) end
            p:endRawStroke()

            assert.equals(0, calls)
            assert.equals(0, #UIManager.shown)
            assert.equals(0, #UIManager.closed)
            assert.is_true(#painted > 300)                  -- it really drew
            assert.equals(1, #p.strokes)
        end)

        it("a stroke drawn with the marker keeps the marker's color and width", function()
            local p = new_pencil()
            p:makeToolBoxProvider().selectPreset(6)  -- Yellow marker, 20
            p:startRawStroke()
            p:addRawPoint(100, 100); p:addRawPoint(140, 100)
            p:endRawStroke()
            local s = p.strokes[1]
            assert.equals("highlighter", s.tool)
            assert.equals(20, s.width)
            assert.equals("Yellow", s.color_name)
        end)

        it("pen-down costs nothing extra unless a hold-still trigger is on", function()
            -- routeStylusSlot only calls beginPickerTracking, which returns at once
            -- (no timer, no scheduled closure on every pen-down) when nothing is enabled
            local body = body_of(source, "routeStylusSlot")
            assert.is_truthy(body:find("beginPickerTracking", 1, true))
            assert.is_nil(body:find("experimental_color_picker", 1, true))
            assert.is_nil(body:find("scheduleColorPickerCheck", 1, true))

            local p = new_pencil()
            local before = UIManager.scheduled
            p:beginPickerTracking(10, 20, "pen")
            assert.equals(before, UIManager.scheduled)
            assert.is_nil(p.color_picker_start_time)

            p.tool_box_hold = true
            p:beginPickerTracking(10, 20, "pen")
            assert.equals(before + 1, UIManager.scheduled)
            assert.is_truthy(p.color_picker_start_time)
        end)

        it("opening the box also drops a live highlighter stroke", function()
            package.loaded["lib/toolbox"] = { new = function(_, o)
                o.dimen = { x = 0, y = 0, w = 1, h = 1 }; o.close = function() end; return o
            end }
            local p = new_pencil()
            p.current_stroke = { page = 1, tool = "highlighter", width = 20, points = { { x = 50, y = 60 } } }
            p.live_highlighter = { stroke = p.current_stroke }
            p:showToolBox(50, 60)
            assert.is_nil(p.current_stroke)
            assert.is_nil(p.live_highlighter)
        end)
    end)
end)
