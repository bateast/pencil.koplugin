--[[--
Unit tests for the tool management module.
Run with: busted spec/penciltool_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- KOReader modules the tool module depends on
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = "BLACK",
        Color8 = function(v) return "GRAY" .. v end,
    }
end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end }
end

local PencilTool = require("lib/penciltool")
local TOOLS = PencilTool.TOOLS
local TYPE = PencilTool.LINUX_TOOLTYPE

describe("PencilTool", function()
    local tool

    before_each(function()
        tool = PencilTool:new()
    end)

    describe("defaults", function()
        it("starts with the pen and no eraser/highlight state", function()
            assert.equals(TOOLS.PEN, tool:getTool())
            assert.is_false(tool.eraser_tool_active)
            assert.is_false(tool.eraser_button_active)
            assert.is_false(tool.erasing)
            assert.is_false(tool.highlighting)
            assert.is_false(tool:isSwaped())
            assert.is_false(tool:isExperimentalTextHighlight())
        end)

        it("has black pen, 3px wide, and a 20px eraser", function()
            local pen = tool:getSettings()
            assert.equals("BLACK", pen.color)
            assert.equals("Black", pen.color_name)
            assert.equals(3, pen.width)
            assert.equals(20, tool:getToolSettings(TOOLS.ERASER).width)
        end)

        it("does not share state between instances", function()
            local other = PencilTool:new()
            tool:setWidth(9)
            tool:swapEraserHighlighter()
            assert.equals(3, other:getSettings().width)
            assert.is_false(other:isSwaped())
        end)

        it("keeps tool names stable (they are stored in saved strokes)", function()
            assert.equals("pen", TOOLS.PEN)
            assert.equals("highlighter", TOOLS.HIGHLIGHTER)
            assert.equals("eraser", TOOLS.ERASER)
        end)
    end)

    describe("tool selection", function()
        it("sets a known tool", function()
            assert.equals(TOOLS.ERASER, tool:setTool(TOOLS.ERASER))
            assert.equals(TOOLS.ERASER, tool:getTool())
        end)

        it("rejects unknown tools and keeps the current one", function()
            assert.is_nil(tool:setTool("PEN"))
            assert.is_nil(tool:setTool(nil))
            assert.equals(TOOLS.PEN, tool:getTool())
        end)

        it("toggles between pen and eraser", function()
            assert.equals(TOOLS.ERASER, tool:togglePenEraser())
            assert.equals(TOOLS.PEN, tool:togglePenEraser())
        end)

        it("toggling from the highlighter goes to the eraser", function()
            tool:setTool(TOOLS.HIGHLIGHTER)
            assert.equals(TOOLS.ERASER, tool:togglePenEraser())
        end)

        it("falls back to pen settings for unknown tools", function()
            assert.equals(tool:getSettings(), tool:getToolSettings("nope"))
            assert.equals(tool:getSettings(), tool:getToolSettings(nil))
        end)
    end)

    describe("settings", function()
        local colors = {
            { name = "Black", color = "BLACK" },
            { name = "Red", color = "RED" },
        }
        local widths = { { width = 3 }, { width = 5 } }

        it("loads color, width and options", function()
            tool:loadSettings({
                pen_color_name = "Red",
                pen_width = 5,
                swap_eraser_and_highlighter = true,
                experimental_text_highlight = true,
            }, colors, widths)
            assert.equals("RED", tool:getSettings().color)
            assert.equals("Red", tool:getSettings().color_name)
            assert.equals(5, tool:getSettings().width)
            assert.is_true(tool:isSwaped())
            assert.is_true(tool:isExperimentalTextHighlight())
        end)

        it("falls back to black for an unknown color name", function()
            tool:loadSettings({ pen_color_name = "Chartreuse" }, colors, widths)
            assert.equals("BLACK", tool:getSettings().color)
            assert.equals("Black", tool:getSettings().color_name)
        end)

        it("ignores a width that is not offered", function()
            tool:loadSettings({ pen_width = 99 }, colors, widths)
            assert.equals(3, tool:getSettings().width)
        end)

        it("always starts with the pen", function()
            tool:setTool(TOOLS.ERASER)
            tool:loadSettings({}, colors, widths)
            assert.equals(TOOLS.PEN, tool:getTool())
        end)

        it("round-trips through exportSettings", function()
            tool:setColor("Red", "RED")
            tool:setWidth(5)
            tool:swapEraserHighlighter()
            tool:experimentalTextHighlight()
            local saved = tool:exportSettings()
            assert.same({
                swap_eraser_and_highlighter = true,
                experimental_text_highlight = true,
                pen_color_name = "Red",
                pen_width = 5,
            }, saved)

            local other = PencilTool:new()
            other:loadSettings(saved, colors, widths)
            assert.same(saved, other:exportSettings())
        end)
    end)

    describe("tool type classification", function()
        it("maps tool types to eraser/highlighter by default", function()
            assert.is_true(tool:isEraserToolType({ tool = TYPE.ERASER }))
            assert.is_false(tool:isEraserToolType({ tool = TYPE.HIGHLIGHTER }))
            assert.is_true(tool:isHighlightingToolType({ tool = TYPE.HIGHLIGHTER }))
            assert.is_false(tool:isHighlightingToolType({ tool = TYPE.ERASER }))
            assert.is_false(tool:isEraserToolType({ tool = TYPE.PEN }))
            assert.is_false(tool:isHighlightingToolType({ tool = TYPE.PEN }))
        end)

        it("swaps them when swap_eraser_and_highlighter is on", function()
            tool:swapEraserHighlighter()
            assert.is_true(tool:isEraserToolType({ tool = TYPE.HIGHLIGHTER }))
            assert.is_false(tool:isEraserToolType({ tool = TYPE.ERASER }))
            assert.is_true(tool:isHighlightingToolType({ tool = TYPE.ERASER }))
            assert.is_false(tool:isHighlightingToolType({ tool = TYPE.HIGHLIGHTER }))
        end)
    end)

    describe("effective tool", function()
        it("uses the selected tool for the pen tip", function()
            assert.equals(TOOLS.PEN, tool:getEffectiveToolForSlot({ tool = TYPE.PEN }))
            tool:setTool(TOOLS.ERASER)
            assert.equals(TOOLS.ERASER, tool:getEffectiveToolForSlot({ tool = TYPE.PEN }))
        end)

        it("uses the eraser for the eraser end, whatever tool is selected", function()
            assert.equals(TOOLS.ERASER, tool:getEffectiveToolForSlot({ tool = TYPE.ERASER }))
        end)

        it("uses the eraser while BTN_TOOL_RUBBER is active", function()
            tool.eraser_tool_active = true
            assert.equals(TOOLS.ERASER, tool:getEffectiveToolForSlot({ tool = TYPE.PEN }))
            assert.equals(TOOLS.ERASER, tool:getEffectiveTool(false, false, false))
        end)

        it("uses the highlighter for the side button", function()
            assert.equals(TOOLS.HIGHLIGHTER, tool:getEffectiveTool(false, false, true))
            assert.equals(TOOLS.HIGHLIGHTER, tool:getEffectiveTool(false, true, false))
            assert.equals(TOOLS.PEN, tool:getEffectiveTool(false, false, false))
        end)

        it("eraser wins over the side button", function()
            assert.equals(TOOLS.ERASER, tool:getEffectiveTool(true, false, true))
        end)

        it("swaps eraser end and highlighter", function()
            tool:swapEraserHighlighter()
            assert.equals(TOOLS.HIGHLIGHTER, tool:getEffectiveTool(true, false, false))
            assert.equals(TOOLS.ERASER, tool:getEffectiveTool(false, true, false))
        end)
    end)

    describe("roles of physical inputs", function()
        local INPUT = PencilTool.INPUT

        it("recognizes key events", function()
            assert.equals(INPUT.ERASER_KEY, PencilTool.inputForKey("Eraser", "Eraser"))
            assert.equals(INPUT.RUBBER, PencilTool.inputForKey(nil, "BTN_TOOL_RUBBER"))
            assert.equals(INPUT.RUBBER, PencilTool.inputForKey(nil, "ToolRubber"))
            assert.equals(INPUT.SIDE_KEY, PencilTool.inputForKey("Highlighter", "Highlighter"))
            assert.equals(INPUT.SIDE_KEY, PencilTool.inputForKey("Stylus", "Stylus"))
            assert.is_nil(PencilTool.inputForKey("Home", "Home"))
            assert.is_nil(PencilTool.inputForKey(nil, nil))
        end)

        it("eraser end/button erases and side button highlights by default", function()
            assert.equals(TOOLS.ERASER, (tool:roleForKey("Eraser", "Eraser")))
            assert.equals(TOOLS.ERASER, (tool:roleForKey(nil, "BTN_TOOL_RUBBER")))
            assert.equals(TOOLS.HIGHLIGHTER, (tool:roleForKey("Highlighter", "Highlighter")))
            assert.equals(TOOLS.ERASER, tool:roleForSlot({ tool = TYPE.ERASER }))
            assert.equals(TOOLS.HIGHLIGHTER, tool:roleForSlot({ tool = TYPE.HIGHLIGHTER }))
            assert.is_nil(tool:roleForSlot({ tool = TYPE.PEN }))
        end)

        it("swap exchanges the two roles everywhere", function()
            tool:swapEraserHighlighter()
            assert.equals(TOOLS.HIGHLIGHTER, (tool:roleForKey("Eraser", "Eraser")))
            assert.equals(TOOLS.HIGHLIGHTER, (tool:roleForKey(nil, "BTN_TOOL_RUBBER")))
            assert.equals(TOOLS.ERASER, (tool:roleForKey("Highlighter", "Highlighter")))
            assert.equals(TOOLS.HIGHLIGHTER, tool:roleForSlot({ tool = TYPE.ERASER }))
            assert.equals(TOOLS.ERASER, tool:roleForSlot({ tool = TYPE.HIGHLIGHTER }))
            assert.is_nil(tool:roleForSlot({ tool = TYPE.PEN }))
        end)

        it("slot events and key events agree on every input, swapped or not", function()
            -- Same physical input => same role, whether it shows up as slot.tool
            -- or as a key press/release (both go through roleForKey).
            local pairs_ = {
                { key = { "Eraser", "Eraser" }, slot = TYPE.ERASER },
                { key = { nil, "BTN_TOOL_RUBBER" }, slot = TYPE.ERASER },
                { key = { "Highlighter", "Highlighter" }, slot = TYPE.HIGHLIGHTER },
                { key = { "Stylus", "Stylus" }, slot = TYPE.HIGHLIGHTER },
            }
            for _, swapped in ipairs({ false, true }) do
                local t = PencilTool:new()
                t.swap_eraser_and_highlighter = swapped
                for _, p in ipairs(pairs_) do
                    assert.equals(t:roleForSlot({ tool = p.slot }), (t:roleForKey(p.key[1], p.key[2])))
                end
            end
        end)

        it("one input is the eraser and the other the highlighter, never both the same", function()
            for _, swapped in ipairs({ false, true }) do
                local t = PencilTool:new()
                t.swap_eraser_and_highlighter = swapped
                assert.are_not.equals(t:roleOfInput(INPUT.ERASER_KEY), t:roleOfInput(INPUT.SIDE_KEY))
                assert.equals(t:roleOfInput(INPUT.ERASER_KEY), t:roleOfInput(INPUT.RUBBER))
            end
        end)
    end)

    describe("effective tool for a raw slot with the side button", function()
        it("side button highlights even if the eraser is the selected tool", function()
            tool:setTool(TOOLS.ERASER)
            assert.equals(TOOLS.HIGHLIGHTER, tool:getEffectiveToolForSlot({ tool = TYPE.PEN }, true))
        end)

        it("highlights from slot.tool alone, before the key event arrives", function()
            assert.equals(TOOLS.HIGHLIGHTER,
                tool:getEffectiveToolForSlot({ tool = TYPE.HIGHLIGHTER }, false))
        end)

        it("the eraser role still wins over the side button", function()
            assert.equals(TOOLS.ERASER, tool:getEffectiveToolForSlot({ tool = TYPE.ERASER }, true))
        end)

        it("swapped: eraser end highlights, side button erases", function()
            tool:swapEraserHighlighter()
            assert.equals(TOOLS.HIGHLIGHTER,
                tool:getEffectiveToolForSlot({ tool = TYPE.ERASER }, false))
            assert.equals(TOOLS.ERASER,
                tool:getEffectiveToolForSlot({ tool = TYPE.HIGHLIGHTER }, false))
        end)

        it("matches the gesture-path rule for every physical input and swap value", function()
            for _, swapped in ipairs({ false, true }) do
                for _, side in ipairs({ false, true }) do
                    local t = PencilTool:new()
                    t.swap_eraser_and_highlighter = swapped
                    for _, tooltype in ipairs({ TYPE.PEN, TYPE.ERASER, TYPE.HIGHLIGHTER }) do
                        assert.equals(
                            t:getEffectiveTool(tooltype == TYPE.ERASER, tooltype == TYPE.HIGHLIGHTER, side),
                            t:getEffectiveToolForSlot({ tool = tooltype }, side))
                    end
                end
            end
        end)
    end)

    describe("detectEraserAndUpdate", function()
        it("activates when the eraser end touches", function()
            assert.is_true(tool:detectEraserAndUpdate({ tool = TYPE.ERASER }))
            assert.is_true(tool.eraser_button_active)
        end)

        it("reports no change while the eraser end stays in use", function()
            tool:detectEraserAndUpdate({ tool = TYPE.ERASER })
            assert.is_nil(tool:detectEraserAndUpdate({ tool = TYPE.ERASER }))
            assert.is_true(tool.eraser_button_active)
        end)

        it("deactivates when the pen tip comes back", function()
            tool:detectEraserAndUpdate({ tool = TYPE.ERASER })
            assert.is_false(tool:detectEraserAndUpdate({ tool = TYPE.PEN }))
            assert.is_false(tool.eraser_button_active)
        end)

        it("reports no change for the pen tip when not erasing", function()
            assert.is_nil(tool:detectEraserAndUpdate({ tool = TYPE.PEN }))
            assert.is_false(tool.eraser_button_active)
        end)

        it("follows the swap option", function()
            tool:swapEraserHighlighter()
            assert.is_nil(tool:detectEraserAndUpdate({ tool = TYPE.ERASER }))
            assert.is_true(tool:detectEraserAndUpdate({ tool = TYPE.HIGHLIGHTER }))
        end)
    end)

    describe("detectHighlighting", function()
        local down = { tool = TYPE.HIGHLIGHTER, id = 0 }
        local lifted = { tool = TYPE.HIGHLIGHTER, id = -1 }

        it("does nothing unless text highlight is enabled", function()
            assert.is_nil(tool:detectHighlighting(down))
        end)

        it("ignores the pen tip", function()
            tool:experimentalTextHighlight()
            assert.is_nil(tool:detectHighlighting({ tool = TYPE.PEN, id = 0 }))
        end)

        it("walks start -> extend -> finish", function()
            tool:experimentalTextHighlight()
            assert.equals("start", tool:detectHighlighting(down))
            tool.highlighting = true  -- caller: highlight really started
            assert.equals("extend", tool:detectHighlighting(down))
            assert.equals("finish", tool:detectHighlighting(lifted))
            tool.highlighting = false
            assert.equals("ignore", tool:detectHighlighting(lifted))
        end)

        it("treats contact id 0 as a contact", function()
            tool:experimentalTextHighlight()
            assert.equals("start", tool:detectHighlighting({ tool = TYPE.HIGHLIGHTER, id = 0 }))
        end)

        it("is sticky: stays in the highlight once started, even if the tool type changes", function()
            tool:experimentalTextHighlight()
            tool.highlighting = true
            assert.equals("extend", tool:detectHighlighting({ tool = TYPE.PEN, id = 1 }))
            assert.equals("finish", tool:detectHighlighting({ tool = TYPE.PEN, id = -1 }))
        end)

        it("keeps trying to start until the caller confirms (e.g. pen began outside a page)", function()
            tool:experimentalTextHighlight()
            assert.equals("start", tool:detectHighlighting(down))
            assert.equals("start", tool:detectHighlighting(down))
        end)

        it("uses the eraser end for text highlight when swapped", function()
            tool:experimentalTextHighlight()
            tool:swapEraserHighlighter()
            assert.equals("start", tool:detectHighlighting({ tool = TYPE.ERASER, id = 0 }))
            assert.is_nil(tool:detectHighlighting({ tool = TYPE.HIGHLIGHTER, id = 0 }))
        end)
    end)
end)
