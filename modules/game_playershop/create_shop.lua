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

function buildEmptySlots()
    clearSlots()
    for i = 1, MAX_SLOTS do
        buildSlotWidget(i)
    end
    refreshSummary()
end

-- ----------------------------------------------------------------------------
-- Item picker: a small popup listing inventoryList; double-click an item to
-- assign it to slot N.
-- ----------------------------------------------------------------------------
local pickerWindow

function openItemPicker(slotIndex)
    if pickerWindow then pickerWindow:destroy() end
    pickerWindow = g_ui.displayUI('playershop.otui', rootWidget)
    pickerWindow = g_ui.createWidget('MainWindow', rootWidget)
    pickerWindow:setText('Selecione item para slot ' .. slotIndex)
    pickerWindow:setSize({ width = 380, height = 360 })

    local list = g_ui.createWidget('TextList', pickerWindow)
    list:addAnchor(AnchorTop, 'parent', AnchorTop)
    list:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    list:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    list:addAnchor(AnchorRight, 'parent', AnchorRight)
    list:setMarginTop(28); list:setMarginBottom(28)

    for _, e in ipairs(inventoryList) do
        local label = ('%dx %s (uid:%d, id:%d)'):format(e.count, e.name, e.uid, e.id)
        local row = g_ui.createWidget('Label', list)
        row:setText(label)
        row.entry = e
        row.onDoubleClick = function()
            assignItemToSlot(slotIndex, e)
            pickerWindow:destroy()
            pickerWindow = nil
        end
    end

    -- request fresh inventory from server
    if modules.game_playershop and modules.game_playershop.sendOpcode then
        modules.game_playershop.sendOpcode(OPCODE_INVENTORY_LIST, '')
    end
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
    s.entryUid = nil; s.entryId = nil
    s.widget.itemSlot:setItemId(0)
    s.widget.itemName:setText('Slot ' .. index .. ' - clique pra escolher')
    s.widget.priceField:setText('')
    s.price = 0
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
            modules.game_textmessage.displayPrivateMessage('Voce precisa colocar um titulo na loja.')
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
end
