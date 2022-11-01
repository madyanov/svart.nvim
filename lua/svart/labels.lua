local utils = require("svart.utils")
local buf = require("svart.buf")

local function is_new_query(query, last_query)
    return not utils.string_prefix(query, last_query)
       and not utils.string_prefix(last_query, query)
end

local function generate_labels(min_count, max_len)
    local labels = { "j", "f", "k", "d", "l", "s", "a", "h", "g", "n", "u", "v", "r", "b", "y", "t", "m", "i", "c", "e", "o", "x", "w", "p", "q", "z" }
    local prefix = ""

    while true do
        if prefix:len() >= max_len - 1 then
            break
        end

        if #labels >= min_count then
            break
        end

        prefix = table.remove(labels, 1)

        local prefixed_labels = {}
        for _, label in ipairs(labels) do
            table.insert(prefixed_labels, prefix .. label)
        end

        for _, label in ipairs(prefixed_labels) do
            table.insert(labels, label)
        end
    end

    return labels
end

function sort_matches(matches)
    -- sort matches by distance to the middle line
    local visible_bounds = buf.get_visible_bounds()
    local middle_line = math.floor(visible_bounds.top + (visible_bounds.bottom - visible_bounds.top) / 2)

    table.sort(matches, function (m1, m2)
        local d1 = math.abs(m1[1] - middle_line)
        local d2 = math.abs(m2[1] - middle_line)

        if d1 ~= d2 then return d1 < d2 end
        if m1[1] ~= m2[1] then return m1[1] < m2[1] end
        return m1[2] < m2[2]
    end)
end

function discard_colliding_labels(matches, labels, query)
    local query_len = query:len()

    for _, match in ipairs(matches) do
        local line = buf.get_line(match[1])
        local next_char = line:sub(match[2] + query_len, match[2] + query_len)

        for i, label in ipairs(labels) do
            if label:sub(1, 1) == next_char then
                table.remove(labels, i)
            end
        end
    end
end

function discard_irrelevant_labeled_matches(labeled_matches, current_label)
    for label, _ in pairs(labeled_matches) do
        if not utils.string_prefix(label, current_label) then
            labeled_matches[label] = nil
        end
    end
end

function label_matches(matches, labels, labels_index)
    local labeled_matches = {}

    for _, match in ipairs(matches) do
        local index_key = table.concat(match, ":")
        local label = labels_index[index_key]

        local label_key = utils.table_key(labels, label)
        if label_key == nil then
            -- if cached label doesn't exists in the allowed labels list,
            -- take a new one from beginning
            label = table.remove(labels, 1)
            labels_index[index_key] = label
        else
            -- remove used cached label from the allowed labels list
            table.remove(labels, label_key)
        end

        if label ~= nil then
            labeled_matches[label] = match
        end
    end

    return labeled_matches
end

local function make_marker()
    local last_query = ""
    local labels_index = {}

    return {
        label_matches = function (matches, query, label)
            if is_new_query(query, last_query) then
                labels_index = {}
            end

            last_query = query

            if query:len() < 1 then
                return {}
            end

            local matches = { unpack(matches) }
            local labels = generate_labels(#matches, 3)

            sort_matches(matches)

            discard_colliding_labels(matches, labels, query)

            labeled_matches = label_matches(matches, labels, labels_index)
            discard_irrelevant_labeled_matches(labeled_matches, label)
            return labeled_matches
        end,
    }
end

return {
    make_marker = make_marker,
}
