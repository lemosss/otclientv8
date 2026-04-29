-- =============================================================================
-- Buyer's view: shows another player's shop (items + prices) and lets us buy.
-- =============================================================================

viewWindow = nil
viewSellerId = 0

local function clearViewItems()
    if not viewWindow then return end
    viewWindow:recursiveGetChildById('viewItems'):destroyChildren()
end

local function buildItemRow(slotIndex, itemId, count, charges, price, name)
    local container = viewWindow:recursiveGetChildById('viewItems')
    local row = g_ui.createWidget('UIWidget', container)
    row:setHeight(36)
    row:setBackgroundColor('#2c2c2c')
    row:setBorderColor('#444')
    row:setBorderWidth(1)
    row:setMarginBottom(2)

    local item = g_ui.createWidget('Item', row)
    item:setVirtual(true)
    item:setItemId(itemId)
    item:setItemCount(count)
    item:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    item:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    item:setMarginLeft(4)
    item:setSize({ width = 32, height = 32 })

    local lbl = g_ui.createWidget('Label', row)
    lbl:setText(('%dx %s @ %d gold'):format(count, name or 'item', price))
    lbl:setColor('#ddd')
    lbl:addAnchor(AnchorLeft, 'prev', AnchorRight)
    lbl:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    lbl:setMarginLeft(8)

    local qty = g_ui.createWidget('TextEdit', row)
    qty:setWidth(40)
    qty:addAnchor(AnchorRight, 'next', AnchorLeft)
    qty:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    qty:setMarginRight(4)
    qty:setText('1')

    local btn = g_ui.createWidget('Button', row)
    btn:setText('Comprar')
    btn:setWidth(70)
    btn:addAnchor(AnchorRight, 'parent', AnchorRight)
    btn:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    btn:setMarginRight(4)
    btn.onClick = function()
        local n = tonumber(qty:getText()) or 0
        if n <= 0 then return end
        local payload = modules.game_playershop.packU32(viewSellerId)
                     .. string.char(slotIndex)
                     .. modules.game_playershop.packU16(n)
        modules.game_playershop.sendOpcode(OPCODE_SHOP_BUY, payload)
    end
end

function shop_view_handle(buffer)
    local pos = 1
    local sellerId; sellerId, pos = modules.game_playershop.readPosU32(buffer, pos)
    local sellerName; sellerName, pos = modules.game_playershop.readPosStr(buffer, pos)
    local shopText; shopText, pos = modules.game_playershop.readPosStr(buffer, pos)

    if not viewWindow then
        viewWindow = g_ui.displayUI('playershop.otui', rootWidget)
        viewWindow = g_ui.createWidget('ShopViewWindow', rootWidget)
    end
    viewWindow:show(); viewWindow:raise(); viewWindow:focus()
    viewSellerId = sellerId

    viewWindow:recursiveGetChildById('sellerLine'):setText('Vendedor: ' .. sellerName)
    viewWindow:recursiveGetChildById('sellerText'):setText(shopText)
    viewWindow:recursiveGetChildById('closeBtn').onClick = function()
        viewWindow:destroy(); viewWindow = nil
    end

    clearViewItems()

    local n = buffer:byte(pos); pos = pos + 1
    for i = 1, n do
        local slotIndex = buffer:byte(pos); pos = pos + 1
        local itemId; itemId, pos = modules.game_playershop.readPosU16(buffer, pos)
        local count;  count,  pos = modules.game_playershop.readPosU16(buffer, pos)
        local price;  price,  pos = modules.game_playershop.readPosU32(buffer, pos)
        local charges;charges,pos = modules.game_playershop.readPosU16(buffer, pos)
        local name;   name,   pos = modules.game_playershop.readPosStr(buffer, pos)
        buildItemRow(slotIndex, itemId, count, charges, price, name)
    end
end

function shop_view_close()
    if viewWindow then viewWindow:destroy(); viewWindow = nil end
end
