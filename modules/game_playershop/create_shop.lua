-- =============================================================================
-- Create-Shop window: lets the seller pick items and prices, then dispatches
-- OPCODE_SHOP_OPEN to the server.
-- =============================================================================

createWindow = nil
inventoryList = {}      -- snapshot received from server
slots = {}              -- [slotIndex] = { entryUid, entryId, count, charges, price, widget }

local MAX_SLOTS = 20

-- ----------------------------------------------------------------------------
local function clearSlots()
    if not createWindow then return end
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    panel:destroyChildren()
    slots = {}
end

local function refreshSummary()
    if not createWindow then return end
    local lbl = createWindow:recursiveGetChildById('summaryLbl')
    local total, count = 0, 0
    for _, s in pairs(slots) do
        if s.entryId then
            count = count + 1
            total = total + (s.price or 0) * (s.count or 1)
        end
    end
    lbl:setText(('%d itens, valor total: %d gold'):format(count, total))
end

-- "Add slot" pseudo-row with a + button. Always rendered last in the panel.
local addRowWidget = nil
local function rebuildAddRow()
    if not createWindow then return end
    if addRowWidget then addRowWidget:destroy(); addRowWidget = nil end
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    local count = 0
    for _ in pairs(slots) do count = count + 1 end
    if count >= MAX_SLOTS then return end
    addRowWidget = g_ui.createWidget('Button', panel)
    addRowWidget:setText('+ adicionar item')
    addRowWidget:setHeight(28)
    addRowWidget.onClick = function()
        local nextIdx = count + 1
        for i = 1, MAX_SLOTS do
            if not slots[i] then nextIdx = i; break end
        end
        addSlot(nextIdx)
    end
end

local function buildSlotWidget(index)
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    local row = g_ui.createWidget('ShopSlot', panel)
    row.itemSlot   = row:getChildById('itemSlot')
    row.itemName   = row:getChildById('itemName')
    row.priceField = row:getChildById('priceField')
    row.removeBtn  = row:getChildById('removeBtn')
    row.itemName:setText('Slot ' .. index .. ' - clique pra escolher')

    row.itemSlot.onClick = function() openItemPicker(index) end

    row.priceField.onTextChange = function(self, text)
        local v = tonumber(text) or 0
        if v < 1 or v > 1000000000 then
            self:setColor('red')
        else
            self:setColor('white')
        end
        slots[index].price = v
        refreshSummary()
    end

    row.removeBtn.onClick = function() removeSlot(index) end

    slots[index] = { widget = row }
    return row
end

-- Add a slot at index (or the first available). Re-renders the add-button.
function addSlot(index)
    if not createWindow then return end
    buildSlotWidget(index)
    rebuildAddRow()
    refreshSummary()
end

-- Initial state: a single empty slot + the add-row button.
function buildEmptySlots()
    clearSlots()
    buildSlotWidget(1)
    rebuildAddRow()
    refreshSummary()
end

-- ----------------------------------------------------------------------------
-- Item picker: popup with a list of items the player has in their DEPOT,
-- aggregated by itemId. User clicks an item, optionally enters quantity for
-- stackables, then it's assigned to the requested slot.
-- ----------------------------------------------------------------------------
local pickerWindow = nil
local pendingSlotIndex = nil
local pickerSelected = nil   -- currently-highlighted PickerCell widget
local pickerSearchText = ''

local function destroyPickerWindow()
    if pickerWindow then pickerWindow:destroy(); pickerWindow = nil end
    pickerSelected = nil
    pickerSearchText = ''
end

-- Truncate a name with ellipsis so it fits in the cell footer.
local function truncate(text, maxLen)
    if not text then return '' end
    if #text <= maxLen then return text end
    return text:sub(1, maxLen - 1) .. '.'
end

function openItemPicker(slotIndex)
    destroyPickerWindow()
    pendingSlotIndex = slotIndex

    -- Ask the server for the latest depot snapshot.
    if modules.game_playershop and modules.game_playershop.sendOpcode then
        modules.game_playershop.sendOpcode(OPCODE_INVENTORY_LIST, '')
    end

    pickerWindow = g_ui.createWidget('PickerWindow', rootWidget)
    pickerWindow:setText('Escolher item do depot (slot ' .. slotIndex .. ')')

    local cancelBtn = pickerWindow:recursiveGetChildById('pickCancelBtn')
    cancelBtn.onClick = destroyPickerWindow

    local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
    okBtn.onClick = function()
        if pickerSelected and pickerSelected.entry then
            promptCountAndAssign(pendingSlotIndex, pickerSelected.entry)
        end
    end

    local searchEdit = pickerWindow:recursiveGetChildById('searchEdit')
    searchEdit.onTextChange = function(self, text)
        pickerSearchText = (text or ''):lower()
        populatePickerList()
    end

    -- ESC closes the picker (scoped to this window).
    g_keyboard.bindKeyPress('Escape', destroyPickerWindow, pickerWindow)
    -- Enter confirms the selected cell.
    g_keyboard.bindKeyPress('Return', function()
        if pickerSelected and pickerSelected.entry then
            promptCountAndAssign(pendingSlotIndex, pickerSelected.entry)
        end
    end, pickerWindow)
    g_keyboard.bindKeyPress('Enter', function()
        if pickerSelected and pickerSelected.entry then
            promptCountAndAssign(pendingSlotIndex, pickerSelected.entry)
        end
    end, pickerWindow)

    -- If we already have a snapshot from a previous open, populate now.
    if inventoryList and #inventoryList > 0 then
        populatePickerList()
    end
end

local function highlightCell(cell)
    if pickerSelected and pickerSelected ~= cell then
        pickerSelected:setOn(false)
    end
    pickerSelected = cell
    if cell then cell:setOn(true) end
    -- Toggle the OK button enabled-state to match selection.
    if pickerWindow then
        local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
        if okBtn then okBtn:setEnabled(cell ~= nil) end
    end
end

function populatePickerList()
    if not pickerWindow then return end
    local panel = pickerWindow:recursiveGetChildById('gridPanel')
    local emptyHint = pickerWindow:recursiveGetChildById('emptyHintLbl')
    if not panel then return end
    panel:destroyChildren()
    pickerSelected = nil
    do
        local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
        if okBtn then okBtn:setEnabled(false) end
    end

    -- Sum quantities already allocated in OTHER slots (the slot we're editing
    -- doesn't count -- the user is replacing whatever was there).
    local allocatedById = {}
    for idx, s in pairs(slots) do
        if idx ~= pendingSlotIndex and s.entryId and s.count and s.count > 0 then
            allocatedById[s.entryId] = (allocatedById[s.entryId] or 0) + s.count
        end
    end

    -- Build filtered list, subtracting already-allocated quantities so the
    -- user can't double-book the same physical stack across slots.
    local matches = {}
    for _, e in ipairs(inventoryList or {}) do
        local available = (e.count or 0) - (allocatedById[e.id] or 0)
        if available > 0 then
            if pickerSearchText == '' or (e.name or ''):lower():find(pickerSearchText, 1, true) then
                local cloned = {
                    id = e.id, uid = e.uid, charges = e.charges,
                    name = e.name, count = available,
                }
                matches[#matches + 1] = cloned
            end
        end
    end
    table.sort(matches, function(a, b) return (a.name or '') < (b.name or '') end)

    if #matches == 0 then
        if emptyHint then
            emptyHint:setText(pickerSearchText ~= '' and '(nenhum item bate com a busca)' or '(seu depot esta vazio)')
            emptyHint:setVisible(true)
        end
        return
    end
    if emptyHint then emptyHint:setVisible(false) end

    for _, e in ipairs(matches) do
        local cell = g_ui.createWidget('PickerCell', panel)
        local cellItem = cell:getChildById('cellItem')
        local cellName = cell:getChildById('cellName')

        cellItem:setItemId(e.id)
        cellItem:setItemCount(e.count)
        cellName:setText(truncate(e.name or '', 8))
        cell:setTooltip(('%dx %s\n(id %d)'):format(e.count, e.name or '', e.id))
        cell.entry = e

        cell.onClick = function(self)
            highlightCell(self)
        end
        cell.onDoubleClick = function(self)
            highlightCell(self)
            promptCountAndAssign(pendingSlotIndex, e)
        end
    end
end

-- For stackable items, prompt for the quantity (default = full stack). For
-- non-stackable charged items (UH/GFB/SD), pick 1.
function promptCountAndAssign(slotIndex, entry)
    if not slotIndex or not entry then return end
    local available = entry.count
    if available <= 1 then
        assignItemDirect(slotIndex, entry, 1)
        destroyPickerWindow()
        return
    end

    local qtyWindow = g_ui.createWidget('QtyWindow', rootWidget)
    qtyWindow:setText(('Quantos? (max %d)'):format(available))

    local edit = qtyWindow:recursiveGetChildById('qtyEdit')
    edit:setText(tostring(available))
    edit:focus()
    -- Select the prefilled value so typing replaces it immediately.
    if edit.selectAll then edit:selectAll() end

    local function commit()
        local n = tonumber(edit:getText()) or available
        if n < 1 then n = 1 end
        if n > available then n = available end
        assignItemDirect(slotIndex, entry, n)
        qtyWindow:destroy()
        destroyPickerWindow()
    end

    qtyWindow:recursiveGetChildById('qtyOkBtn').onClick = commit
    qtyWindow:recursiveGetChildById('qtyCancelBtn').onClick = function()
        qtyWindow:destroy()
    end
    g_keyboard.bindKeyPress('Return', commit, qtyWindow)
    g_keyboard.bindKeyPress('Enter', commit, qtyWindow)
    g_keyboard.bindKeyPress('Escape', function() qtyWindow:destroy() end, qtyWindow)
end

function assignItemDirect(index, entry, count)
    local s = slots[index]
    if not s or not s.widget then return end
    s.entryUid = 0  -- depot-aggregated; server will look up by id
    s.entryId  = entry.id
    s.count    = count
    s.charges  = entry.charges or 0
    s.widget.itemSlot:setItemId(entry.id)
    s.widget.itemSlot:setItemCount(count)
    s.widget.itemName:setText(('%dx %s'):format(count, entry.name or ('id ' .. entry.id)))
    refreshSummary()
end

function assignItemToSlot(index, entry)
    local s = slots[index]
    if not s or not s.widget then return end
    s.entryUid = entry.uid
    s.entryId  = entry.id
    s.count    = entry.count
    s.charges  = entry.charges
    s.widget.itemSlot:setItemId(entry.id)
    s.widget.itemSlot:setItemCount(entry.count)
    s.widget.itemName:setText(('%dx %s'):format(entry.count, entry.name))
    refreshSummary()
end

function removeSlot(index)
    local s = slots[index]
    if not s or not s.widget then return end
    s.widget:destroy()
    slots[index] = nil
    -- Always keep at least one empty slot in the window.
    local count = 0
    for _ in pairs(slots) do count = count + 1 end
    if count == 0 then buildSlotWidget(1) end
    rebuildAddRow()
    refreshSummary()
end

-- ----------------------------------------------------------------------------
-- Open / close the create window
-- ----------------------------------------------------------------------------
function openCreateShop()
    if createWindow then createWindow:show(); createWindow:raise(); return end
    createWindow = g_ui.displayUI('playershop.otui', rootWidget)
    -- The OTUI imports several styles; pick the right one explicitly.
    createWindow = g_ui.createWidget('CreateShopWindow', rootWidget)
    createWindow:show()
    createWindow:raise()
    createWindow:focus()

    buildEmptySlots()
    -- restore cached text (per session)
    if lastSavedText then
        createWindow:recursiveGetChildById('shopText'):setText(lastSavedText)
    end
    if lastSavedSlots then
        for i, e in pairs(lastSavedSlots) do
            assignItemToSlot(i, e)
            slots[i].price = e.price or 0
            slots[i].widget.priceField:setText(tostring(e.price or 0))
        end
    end

    createWindow:recursiveGetChildById('cancelBtn').onClick = function()
        closeCreateShop()
    end
    createWindow:recursiveGetChildById('startBtn').onClick = function()
        commitCreateShop()
    end

    -- Bind Escape to close the window (scoped to the window so it doesn't
    -- conflict with other ESC handlers).
    g_keyboard.bindKeyPress('Escape', closeCreateShop, createWindow)

    -- ask server for inventory snapshot to populate the picker later
    if modules.game_playershop and modules.game_playershop.sendOpcode then
        modules.game_playershop.sendOpcode(OPCODE_INVENTORY_LIST, '')
    end
end

function closeCreateShop()
    if createWindow then createWindow:destroy(); createWindow = nil end
    if pickerWindow then pickerWindow:destroy(); pickerWindow = nil end
end

function commitCreateShop()
    local text = createWindow:recursiveGetChildById('shopText'):getText() or ''
    if text:gsub("%s+", "") == "" then
        if modules.game_textmessage then
            modules.game_textmessage.displayBroadcastMessage('Voce precisa colocar um titulo na loja.')
        end
        createWindow:recursiveGetChildById('shopText'):focus()
        return
    end
    local payload = ''
    payload = payload .. modules.game_playershop.packStr(text)
    -- count of filled slots
    local filled = {}
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s and s.entryId then filled[#filled + 1] = { idx = i, e = s } end
    end
    payload = payload .. string.char(#filled)
    for _, f in ipairs(filled) do
        local s = f.e
        payload = payload .. modules.game_playershop.packU32(s.entryUid or 0)
        payload = payload .. modules.game_playershop.packU16(s.entryId or 0)
        payload = payload .. modules.game_playershop.packU16(s.count or 1)
        payload = payload .. modules.game_playershop.packU32(s.price or 0)
    end
    modules.game_playershop.sendOpcode(OPCODE_SHOP_OPEN, payload)
    -- Optimistic: lock immediately so user can't dash off mid-broadcast.
    -- onReject (server denial) and STATE_BROADCAST(closed) both reset to false.
    iAmSelling = true

    -- cache for next time
    lastSavedText = text
    lastSavedSlots = {}
    for _, f in ipairs(filled) do
        lastSavedSlots[f.idx] = {
            uid = f.e.entryUid, id = f.e.entryId, count = f.e.count,
            charges = f.e.charges, name = '', price = f.e.price,
        }
    end
    closeCreateShop()
end

-- ----------------------------------------------------------------------------
-- Server -> client: inventory list payload
-- ----------------------------------------------------------------------------
function create_shop_inventory(buffer)
    local pos = 1
    local n; n, pos = modules.game_playershop.readPosU16(buffer, pos)
    inventoryList = {}
    for i = 1, n do
        local uid, id, count, charges, name
        uid,    pos = modules.game_playershop.readPosU32(buffer, pos)
        id,     pos = modules.game_playershop.readPosU16(buffer, pos)
        count,  pos = modules.game_playershop.readPosU16(buffer, pos)
        charges,pos = modules.game_playershop.readPosU16(buffer, pos)
        name,   pos = modules.game_playershop.readPosStr(buffer, pos)
        inventoryList[#inventoryList + 1] = {
            uid = uid, id = id, count = count, charges = charges, name = name
        }
    end
    -- Refresh the picker if open.
    if populatePickerList then populatePickerList() end
end
