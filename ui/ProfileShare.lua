local addonName, ns = ...

local Const = ns.Constants

local ProfileShare = {}
ns.ProfileShare = ProfileShare

local frame
local mode = "export"

local EXPORT_HINT = "Your profile, as a shareable string. Press Ctrl+C to copy it."
local IMPORT_HINT = "Paste a profile string here (Ctrl+V), then press Import."

local function SetDialogTitle(dialog, text)
    if dialog.SetTitle and pcall(dialog.SetTitle, dialog, text) then return end

    local titleText = (dialog.TitleContainer and dialog.TitleContainer.TitleText)
        or dialog.TitleText
        or _G["CDMCProfileShareTitleText"]
    if titleText then titleText:SetText(text) end
end

local function Build()
    if frame then return frame end

    frame = CreateFrame("Frame", "CDMCProfileShare", UIParent, "ButtonFrameTemplate")
    frame:SetSize(500, 340)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    if _G.UISpecialFrames then
        tinsert(UISpecialFrames, "CDMCProfileShare")
    end

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", 14, -34)
    frame.hint:SetPoint("TOPRIGHT", -14, -34)
    frame.hint:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "CDMCProfileShareScroll", frame,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -58)
    scroll:SetPoint("BOTTOMRIGHT", -36, 44)
    frame.scroll = scroll

    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
    background:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 6, -6)
    background:SetColorTexture(0, 0, 0, 0.4)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(430)
    edit:SetHeight(600)
    edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function() ProfileShare:Hide() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit

    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)

    frame.action = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.action:SetSize(120, 22)
    frame.action:SetPoint("BOTTOMRIGHT", -16, 14)

    frame.selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.selectAll:SetSize(120, 22)
    frame.selectAll:SetPoint("BOTTOMLEFT", 16, 14)
    frame.selectAll:SetText("Select All")
    frame.selectAll:SetScript("OnClick", function()
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end)

    frame.switch = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.switch:SetSize(140, 22)
    frame.switch:SetPoint("LEFT", frame.selectAll, "RIGHT", 8, 0)
    frame.switch:SetScript("OnClick", function()
        if mode == "export" then
            ProfileShare:ShowImport()
        else
            ProfileShare:ShowExport()
        end
    end)

    return frame
end

function ProfileShare:ShowExport()
    Build()
    mode = "export"

    local text, err = ns.Serialization:Export()
    if not text then
        ns.Print("|cffff5555" .. tostring(err) .. "|r")
        return
    end

    SetDialogTitle(frame, "Export Profile")
    frame.hint:SetText(EXPORT_HINT)
    frame.edit:SetText(text)

    frame.action:SetText("Close")
    frame.action:SetScript("OnClick", function() ProfileShare:Hide() end)
    frame.selectAll:Show()
    frame.switch:SetText("Import Instead")
    frame.switch:ClearAllPoints()
    frame.switch:SetPoint("LEFT", frame.selectAll, "RIGHT", 8, 0)

    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end

function ProfileShare:ShowImport()
    Build()
    mode = "import"

    SetDialogTitle(frame, "Import Profile")
    frame.hint:SetText(IMPORT_HINT)
    frame.edit:SetText("")

    frame.action:SetText("Import")
    frame.action:SetScript("OnClick", function()
        local text = frame.edit:GetText()
        ProfileShare:Hide()
        ns.Core:ImportString(text)
    end)
    frame.selectAll:Hide()
    frame.switch:SetText("Export Instead")
    frame.switch:ClearAllPoints()
    frame.switch:SetPoint("BOTTOMLEFT", 16, 14)

    frame:Show()
    frame.edit:SetFocus()
end

function ProfileShare:Hide()
    if frame then frame:Hide() end
end

function ProfileShare:IsShown()
    return frame ~= nil and frame:IsShown()
end

function ProfileShare:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:ShowExport()
    end
end
