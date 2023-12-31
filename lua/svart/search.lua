local win = require("svart.win")
local buf = require("svart.buf")

local function search_regex(exact, query)
    return exact and "\\V" .. vim.fn.escape(query, "\\") or query
end

local function match_len(line, col, regex)
    local line_part = line:sub(col)
    local match_str = vim.fn.matchstr(line_part, regex)
    return #match_str
end

local function directional_search(exact, query, backwards, bounds)
    if query == "" then
        return function() return nil end
    end

    local search_flags = backwards and "b" or ""
    local search_stopline = backwards and bounds.top or bounds.bottom

    local saved_view_state = win.save_view_state()
    local first_search = true

    return function()
        -- capture match under cursor on first search
        local cursor_match_flag = first_search and not backwards and "c" or ""
        first_search = false

        local regex = search_regex(exact, query)
        local ok, match = pcall(vim.fn.searchpos, regex, search_flags .. cursor_match_flag, search_stopline)
        if not ok then return saved_view_state.restore() end

        local line_nr, col = unpack(match)
        if line_nr == 0 and col == 0 then return saved_view_state.restore() end

        local match_len = exact and #query or match_len(buf.line_at(line_nr), col, regex)
        return { line = line_nr, col = col, len = match_len }
    end
end

local M = {}

function M.update_register(exact, query)
    if query == "" then return end

    local saved_view_state = win.save_view_state()
    local regex = search_regex(exact, query)

    vim.fn.setreg("/", regex)

    saved_view_state.restore()
end

function M.search(exact, query, win_ctx)
    local matches = {
        count = 0,
        wins = {},
    }

    win_ctx.for_each(function(win_id)
        local bounds = buf.visible_bounds()
        local cursor = win.cursor()

        local win_matches = {
            win_id = win_id,
            bounds = bounds,
            cursor = cursor,
            list = {},
        }

        -- search forward
        for match in directional_search(exact, query, false, bounds) do
            match.win_id = win_id
            table.insert(win_matches.list, match)
        end

        -- then search backwards
        for match in directional_search(exact, query, true, bounds) do
            match.win_id = win_id
            table.insert(win_matches.list, match)
        end

        matches.count = matches.count + #win_matches.list
        table.insert(matches.wins, win_matches)
    end)

    return matches
end

function M.make_context(config, win, excluded_win_ids)
    local cursor = win.cursor()

    local all_matches = {}
    local current_idx = 0
    local current_match = nil

    local set_current_index = function(idx)
        current_idx = idx
        current_match = all_matches[idx]
    end

    local this = {}

    this.reset = function(matches)
        all_matches = {}

        -- collect matches from all windows
        for _, win_matches in ipairs(matches.wins) do
            if excluded_win_ids[win_matches.win_id] == nil then
                local matches_copy = { unpack(win_matches.list) }

                -- sort matches by line number for easier navigation
                table.sort(matches_copy, function(match1, match2)
                    if match1.line ~= match2.line then return match1.line < match2.line end
                    return match1.col < match2.col
                end)

                for _, match in ipairs(matches_copy) do
                    table.insert(all_matches, match)
                end
            end
        end

        -- don't change current match if it's equal to the previous one
        for i, match in ipairs(all_matches) do
            if current_match ~= nil
                and match.win_id == current_match.win_id
                and match.line == current_match.line
                and match.col == current_match.col then
                set_current_index(i)
                return
            end
        end

        -- or set current match to the first match after the cursor
        local last_idx = 0

        for i, match in ipairs(all_matches) do
            if (match.line == cursor.line and match.col >= cursor.col)
                or match.line > cursor.line then
                set_current_index(i)
                return
            end

            last_idx = i
        end

        -- or set current match to the nearest to the cursor one
        set_current_index(last_idx)
    end

    this.is_empty = function()
        return next(all_matches) == nil
    end

    this.best_match = function()
        return all_matches[current_idx]
    end

    this.next_match = function()
        if current_idx == 0 then return end
        local last_idx = config.search_wrap_around and 1 or #all_matches
        set_current_index(current_idx >= #all_matches and last_idx or current_idx + 1)
    end

    this.prev_match = function()
        if current_idx == 0 then return end
        local last_idx = config.search_wrap_around and #all_matches or 1
        set_current_index(current_idx <= 1 and last_idx or current_idx - 1)
    end

    return this
end

function M.test(tests)
    -- search_regex
    do
        local query = [[ \n test \n ]]

        -- exact
        local regex = search_regex(true, query)
        tests.assert_eq(regex, [[\V \\n test \\n ]])

        -- regex
        regex = search_regex(false, query)
        tests.assert_eq(regex, query)
    end

    -- make_context
    do
        local config = { search_wrap_around = true }
        local win = { cursor = function() return { line = 2, col = 1 } end }
        local ctx = M.make_context(config, win, { [3] = true })

        -- new context is empty
        assert(ctx.is_empty())
        tests.assert_eq(ctx.best_match(), nil)

        -- add some matches from different windows
        ctx.reset({ wins = {
            {
                win_id = 1,
                list = { { line = 1, col = 1 }, { line = 3, col = 1 } },
            },
            {
                win_id = 2,
                list = { { line = 4, col = 1 } },
            },
            {
                win_id = 3,
                list = { { line = 5, col = 1 } },
            },
        } })
        assert(not ctx.is_empty())
        tests.assert_eq(ctx.best_match(), { line = 3, col = 1 })

        -- next match
        ctx.next_match()
        tests.assert_eq(ctx.best_match(), { line = 4, col = 1 })

        -- wrap around
        ctx.next_match()
        tests.assert_eq(ctx.best_match(), { line = 1, col = 1 })
        ctx.prev_match()
        tests.assert_eq(ctx.best_match(), { line = 4, col = 1 })

        -- prev match
        ctx.prev_match()
        tests.assert_eq(ctx.best_match(), { line = 3, col = 1 })

        -- preseve best match when adding new matches
        ctx.reset({ wins = {
            {
                win_id = 1,
                list = { { line = 1, col = 1 }, { line = 3, col = 1 } },
            },
        } })
        tests.assert_eq(ctx.best_match(), { line = 3, col = 1 })

        -- clear best match if there's no in matches
        ctx.reset({ wins = { { win_id = 1, list = { { line = 1, col = 1 } } } } })
        tests.assert_eq(ctx.best_match(), { line = 1, col = 1 })

        -- wrap around disabled
        config = { search_wrap_around = false }
        ctx = M.make_context(config, win, {})
        ctx.reset({ wins = {
            {
                win_id = 1,
                list = { { line = 1, col = 1 }, { line = 3, col = 1 } },
            },
        } })

        ctx.next_match()
        tests.assert_eq(ctx.best_match(), { line = 3, col = 1 })
        ctx.next_match()
        tests.assert_eq(ctx.best_match(), { line = 3, col = 1 })

        ctx.prev_match()
        tests.assert_eq(ctx.best_match(), { line = 1, col = 1 })
        ctx.prev_match()
        tests.assert_eq(ctx.best_match(), { line = 1, col = 1 })
    end

    -- match_len
    do
        local line = "test line"

        -- beginning
        tests.assert_eq(match_len(line, 1, "t.s."), 4)

        -- end
        tests.assert_eq(match_len(line, 5, "l.n."), 4)

        -- middle
        tests.assert_eq(match_len(line, 1, "st.li"), 5)

        -- whole
        tests.assert_eq(match_len(line, 1, ".*"), #line)
    end
end

return M
