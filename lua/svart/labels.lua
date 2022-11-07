local config = require("svart.config")
local utils = require("svart.utils")
local buf = require("svart.buf")
local win = require("svart.win")

local function make_labels_pool(atoms, min_count, max_len)
    local generated = false
    local labels = utils.make_bimap()
    local discarded = {}

    local available = function(label)
        -- label isn't available if it's prefix
        -- exists in the discarded labels list
        for discarded_label, _ in pairs(discarded) do
            if utils.string_prefix(label, discarded_label) then
                return false
            end
        end

        return true
    end

    local generate_labels_if_needed = function()
        if generated then return end
        generated = true

        while true do
            local tail = {}

            if labels.first() == nil then
                -- first time generate labels from atoms directly
                for _, atom in ipairs(atoms) do
                    if available(atom) then
                        table.insert(tail, atom)
                    end
                end
            else
                -- then concatenate atoms one to another to create more labels
                for _, label in labels.pairs() do
                    for _, atom in ipairs(atoms) do
                        if atom ~= label:sub(-#atom) then -- skip atom if it's equal
                                                          -- to the label's last char
                            local new_label = label .. atom

                            if #new_label <= max_len and available(new_label) then
                                table.insert(tail, new_label)
                            end
                        end
                    end
                end
            end

            -- nothing generated, break to prevent infinite loop
            if next(tail) == nil then
                return
            end

            for _, label in ipairs(tail) do
                -- add freshly generated label to the pool
                -- and remove it's prefix from the pool to avoid ambiguity
                local prefix = label:sub(1, -2)
                labels.remove_value(prefix)
                labels.append(label)

                if labels.count() >= min_count then
                    return
                end
            end
        end
    end

    return {
        available = available,
        discard = function(label)
            assert(not generated)
            assert(label ~= nil)
            assert(label ~= "")
            discarded[label] = true
        end,
        first = function()
            generate_labels_if_needed()
            return labels.first()
        end,
        take = function()
            generate_labels_if_needed()
            return labels.drop_first()
        end,
    }
end

local function sort_matches(matches, bounds)
    -- sort labels by distance to the middle line
    local middle_line = math.floor(bounds.top + (bounds.bottom - bounds.top) / 2)

    table.sort(matches, function(match1, match2)
        local dist1 = math.abs(match1.line - middle_line)
        local dist2 = math.abs(match2.line - middle_line)

        if dist1 ~= dist2 then return dist1 < dist2 end
        if match1.line ~= match2.line then return match1.line < match2.line end
        return match1.col < match2.col
    end)
end

local function discard_conflicting_labels(labels_pool, matches, query, buf)
    -- discard labels that may conflict with next possible query character
    for _, match in ipairs(matches) do
        local line = buf.line_at(match.line)
        local next_char = line:sub(match.col + #query, match.col + #query):lower()

        if next_char ~= "" then
            labels_pool.discard(next_char)
        end
    end
end

-- todo: write tests
local function label_prev_matches(matches, labels_pool, prev_labeled_matches, labeled_matches)
    -- try to take lables from previous search
    for _, match in ipairs(matches) do
        local label = prev_labeled_matches.key(match)

        if label ~= nil and labels_pool.available(label) then
            labels_pool.discard(label)
            labeled_matches.set(label, match)
        end
    end
end

-- todo: write tests
local function label_matches(matches, labels_pool, labeled_matches)
    -- take labels from the pool
    for _, match in ipairs(matches) do
        local label = labels_pool.first()

        if label ~= nil then
            assert(labels_pool.take() == label)
            local prev_label = labeled_matches.key(match)

            if prev_label == nil then
                labeled_matches.set(label, match)
            elseif #label < #prev_label then -- replace label from previous
                                             -- search with shorter one
                labeled_matches.replace(prev_label, label, match)
            end
        end
    end
end

local function discard_irrelevant_labels(labeled_matches, current_label)
    -- discard irrelevant labels after start typing label to go to
    for label, _ in labeled_matches.pairs() do
        if not utils.string_prefix(label, current_label) then
            labeled_matches.remove_key(label)
        end
    end
end

-- todo: write tests
local function discard_offscreen_labels(labeled_matches, bounds)
    -- discard labels out of current screen bounds
    for label, match in labeled_matches.pairs() do
        if match.line < bounds.top or match.line > bounds.bottom then
            labeled_matches.remove_value(match)
        end
    end
end

local function make_context()
    local history = {}
    local labeled_matches = utils.make_bimap()

    -- convert atoms string to array
    local atoms = {}
    config.label_atoms:gsub(".", function(char) table.insert(atoms, char) end)

    return {
        label_matches = function(matches, query, label)
            -- query too short to label matches, break
            if #query < config.label_min_query_len then
                history = {}
                labeled_matches = utils.make_bimap()
                return
            end

            labeled_matches = history[query] ~= nil
                and history[query].copy()
                or utils.make_bimap()

            -- labels from previous search
            local prev_query = query:sub(1, -2)
            local prev_labeled_matches = history[prev_query] ~= nil
                and history[prev_query].copy()
                or utils.make_bimap()

            local labels_pool = make_labels_pool(atoms, matches.count, config.label_max_len)

            for _, win_matches in ipairs(matches.wins) do
                win.run_on(win_matches.win_id, function()
                    discard_offscreen_labels(labeled_matches, win_matches.bounds)
                    discard_conflicting_labels(labels_pool, win_matches.list, query, buf)
                    label_prev_matches(matches, labels_pool, prev_labeled_matches, labeled_matches)
                end)
            end

            for _, win_matches in ipairs(matches.wins) do
                win.run_on(win_matches.win_id, function()
                    -- todo: support different sort strategies
                    -- todo: allow to spread short labels between windows
                    sort_matches(win_matches.list, win_matches.bounds)
                    label_matches(win_matches.list, labels_pool, labeled_matches)
                end)
            end

            history[query] = labeled_matches.copy()

            if config.label_hide_irrelevant and label ~= "" then
                discard_irrelevant_labels(labeled_matches, label)
            end
        end,
        labeled_matches = function()
            return labeled_matches
        end,
        labels = function()
            return labeled_matches.keys()
        end,
        has_label = function(label)
            return labeled_matches.has_key(label)
        end,
        match = function(label)
            return labeled_matches.value(label)
        end,
    }
end

local function test()
    local tests = require("svart.tests")

    -- make_labels_pool
    do
        -- generation
        local atoms = { "a", "b", "c", "d" }
        local labels_pool = make_labels_pool(atoms, 1, 1)
        assert(labels_pool.available("a"))
        assert(labels_pool.available("b"))
        assert(labels_pool.available("c"))
        assert(labels_pool.available("d"))
        tests.assert_eq(labels_pool.take(), "a")
        tests.assert_eq(labels_pool.take(), nil)

        labels_pool = make_labels_pool(atoms, 6, 1)
        tests.assert_eq(labels_pool.take(), "a")
        tests.assert_eq(labels_pool.take(), "b")
        tests.assert_eq(labels_pool.take(), "c")
        tests.assert_eq(labels_pool.take(), "d")
        tests.assert_eq(labels_pool.take(), nil)

        labels_pool = make_labels_pool(atoms, 6, 2)
        tests.assert_eq(labels_pool.take(), "b")
        tests.assert_eq(labels_pool.take(), "c")
        tests.assert_eq(labels_pool.take(), "d")
        tests.assert_eq(labels_pool.take(), "ab")
        tests.assert_eq(labels_pool.take(), "ac")
        tests.assert_eq(labels_pool.take(), "ad")
        tests.assert_eq(labels_pool.take(), nil)

        labels_pool = make_labels_pool(atoms, 9, 2)
        tests.assert_eq(labels_pool.take(), "d")
        tests.assert_eq(labels_pool.take(), "ab")
        tests.assert_eq(labels_pool.take(), "ac")
        tests.assert_eq(labels_pool.take(), "ad")
        tests.assert_eq(labels_pool.take(), "ba")
        tests.assert_eq(labels_pool.take(), "bc")
        tests.assert_eq(labels_pool.take(), "bd")
        tests.assert_eq(labels_pool.take(), "ca")
        tests.assert_eq(labels_pool.take(), "cb")
        tests.assert_eq(labels_pool.take(), nil)

        -- discard
        labels_pool = make_labels_pool(atoms, 6, 2)
        labels_pool.discard("a")
        assert(not labels_pool.available("a"))
        assert(not labels_pool.available("ab"))
        tests.assert_eq(labels_pool.take(), "d")
        tests.assert_eq(labels_pool.take(), "ba")
        tests.assert_eq(labels_pool.take(), "bc")
        tests.assert_eq(labels_pool.take(), "bd")
        tests.assert_eq(labels_pool.take(), "ca")
        tests.assert_eq(labels_pool.take(), "cb")
        tests.assert_eq(labels_pool.take(), nil)
    end

    -- sort_matches
    do
        local bounds = { top = 1, bottom = 9 }
        local matches = { { 2, 1 }, { 5, 1 }, { 7, 1 } }
        sort_matches(matches, bounds)
        tests.assert_eq(matches[1][1], 5)
        tests.assert_eq(matches[2][1], 7)
        tests.assert_eq(matches[3][1], 2)

        bounds = { top = 1, bottom = 1 }
        matches = { { 1, 1 }, { 1, 2 } }
        sort_matches(matches, bounds)
        tests.assert_eq(matches[1][2], 1)
        tests.assert_eq(matches[2][2], 2)
    end

    -- discard_conflicting_labels
    do
        local labels_pool = make_labels_pool({}, 1, 1)
        local matches = { { 1, 1 }, { 1, 6 } }
        local query = "_"
        local buf = { line_at = function(line_nr) return "test line" end }
        discard_conflicting_labels(labels_pool, matches, query, buf)
        assert(not labels_pool.available("e"))
        assert(not labels_pool.available("in"))
    end

    -- label_matches
    do
        local matches = { { 2, 1 }, { 5, 1 }, { 7, 1 }, { 8, 1 }, { 9, 1 } }
        local labels_pool = make_labels_pool({ "a", "b", "c", "d", "e", "f" }, #matches, 2)
        local prev_labeled_matches = utils.make_bimap({ x = { 2, 1 }, c = { 9, 1 }, zz = { 7, 1 } })
        local labeled_matches = utils.make_bimap()
        label_matches(matches, labels_pool, prev_labeled_matches, labeled_matches)
        tests.assert_eq(labeled_matches.key({ 5, 1 }), "b")
        tests.assert_eq(labeled_matches.key({ 9, 1 }), "c")
        tests.assert_eq(labeled_matches.key({ 7, 1 }), "d")
        tests.assert_eq(labeled_matches.key({ 8, 1 }), "e")
        tests.assert_eq(labeled_matches.key({ 2, 1 }), "x")
    end

    -- discard_irrelevant_labels
    do
        local labeled_matches = utils.make_bimap({ aa = { 2, 1 }, ba = { 3, 1 }, bb = { 1, 1 } })
        local current_label = "b"
        discard_irrelevant_labels(labeled_matches, current_label)
        tests.assert_eq(labeled_matches.value("aa"), nil)
        tests.assert_eq(labeled_matches.key({ 3, 1 }), "ba")
        tests.assert_eq(labeled_matches.key({ 1, 1 }), "bb")
    end
end

return {
    make_context = make_context,
    test = test,
}
