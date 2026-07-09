local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local Workspace  = game:GetService("Workspace")
local CoreGui    = game:GetService("CoreGui")
local Lighting   = game:GetService("Lighting")
local Tween      = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer

if getgenv then
    if getgenv().syntax then pcall(function() getgenv().syntax._unload() end) end
    if getgenv().SynapsePL then pcall(function() getgenv().SynapsePL._unload() end) end
end
local Hub = {}; if getgenv then getgenv().syntax = Hub end

local F = {
    Aim = { On=false, Held=false, Part="Head", TeamCheck=true, WallCheck=false, Smooth=0.20, FOV=120, ShowFOV=true, Predict=0.0, Trigger=false, TrigDelay=60, Silent=false, Fire=false },
    ESP = { On=false, Box=true, Filled=false, Name=true, Dist=true, Health=true, Tracer=false, Skeleton=false, EnemiesOnly=false },
    Mov = { Speed=false, SpeedV=50, JumpOn=false, JumpV=80, Fly=false, FlyV=2.5, Noclip=false, InfJump=false, Invis=false },
    Wld = { Fullbright=false, NoFog=false, FOV=70, AntiAFK=false },
    UI  = { Boxes=true, RGB=false },
}
Hub.F = F
local attached = true   -- features are always live; the old manual "Attach" step was removed
local conns = {}
local function bind(s,f) local c=s:Connect(f); conns[#conns+1]=c; return c end

local function cam()  return Workspace.CurrentCamera end
local function char() return LocalPlayer.Character end
local function root() local c=char(); return c and (c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")) end
local function hum()  local c=char(); return c and c:FindFirstChildOfClass("Humanoid") end
local function alive(p) local c=p.Character; local h=c and c:FindFirstChildOfClass("Humanoid"); return h and h.Health>0, c, h end
local function key(k) return UIS:IsKeyDown(k) end
-- crosshair origin for aim: the MOUSE position. Prison Life aims the gun at the cursor
-- (ViewportPointToRay), so the FOV circle + target selection track the mouse, not screen center.
-- Drawing + WorldToViewportPoint share GetMouseLocation's origin, so use it directly — subtracting
-- the GUI inset (the old code) pushed the circle ~36px above the cursor.
local function aimOrigin()
    return UIS:GetMouseLocation()
end
-- smooth (tweened) teleport: glide the root to the target over `dur` on Heartbeat (post-physics, so
-- it replicates) instead of snapping. Zeroing velocity keeps physics from fighting the slide.
local function tweenTP(cf, dur)
    local r=root(); if not (r and cf) then return end
    dur=dur or 0.22
    local startCF=r.CFrame; local t0=os.clock()
    while true do
        local a=(os.clock()-t0)/dur
        if a>=1 then break end
        a=1-(1-a)*(1-a)  -- ease-out
        pcall(function() r.CFrame=startCF:Lerp(cf,a); r.AssemblyLinearVelocity=Vector3.zero end)
        RunService.Heartbeat:Wait()
    end
    pcall(function() r.CFrame=cf; r.AssemblyLinearVelocity=Vector3.zero end)
end
local function tpMove(cf) if cf then task.spawn(tweenTP,cf,0.22) end end
local ENEMY_MODES={"Enemy team","Cops (Guards)","Criminals","Everyone"}
local enemyMode=1
local function isEnemy(p)
    if not p or p==LocalPlayer then return false end
    local m=ENEMY_MODES[enemyMode]; local tn=p.Team and p.Team.Name:lower() or ""
    if m=="Everyone" then return true
    elseif m=="Cops (Guards)" then return (tn:find("guard") or tn:find("police") or tn:find("cop"))~=nil
    elseif m=="Criminals" then return (tn:find("crim") or tn:find("mafia"))~=nil
    else return p.Team~=LocalPlayer.Team end
end

local Aim = {}
do
    local function los(part)
        local rp=RaycastParams.new(); rp.FilterType=Enum.RaycastFilterType.Exclude; rp.FilterDescendantsInstances={char()}
        local o=cam().CFrame.Position; local r=Workspace:Raycast(o,part.Position-o,rp)
        return (not r) or r.Instance:IsDescendantOf(part.Parent)
    end
    function Aim.getTarget(maxFov, needLos)
        local best,bd=nil,maxFov or F.Aim.FOV; local center=aimOrigin()
        for _,p in ipairs(Players:GetPlayers()) do
            if p~=LocalPlayer and isEnemy(p) then
                local ok,c=alive(p); local part=ok and c:FindFirstChild(F.Aim.Part)
                if part then
                    local sp,on=cam():WorldToViewportPoint(part.Position)
                    if on then local d=(Vector2.new(sp.X,sp.Y)-center).Magnitude
                        if d<bd and (((not needLos) and not F.Aim.WallCheck) or los(part)) then bd,best=d,part end end
                end
            end
        end
        return best
    end
end
local function fireClick()
    if mouse1press and mouse1release then pcall(function() mouse1press(); task.wait(0.02); mouse1release() end)
    elseif mouse1click then pcall(mouse1click) end
end

-- wallbang = camera aim-lock through walls (nearest on-screen enemy ignoring line-of-sight).
-- wallbang itself never touches the gun remote; only silent aim hooks ShootEvent (safely) below.
local wallbang=false
local function wallTarget()
    local best,bd=nil,F.Aim.FOV; local center=aimOrigin()
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and isEnemy(p) then local ok,c=alive(p); local part=ok and c:FindFirstChild(F.Aim.Part)
            if part then local sp,on=cam():WorldToViewportPoint(part.Position)
                if on then local d=(Vector2.new(sp.X,sp.Y)-center).Magnitude; if d<bd then bd,best=d,part end end end
        end
    end
    return best
end
if getgenv then getgenv().syntax_wall=false end

-- Prison Life shoot remote. Verified format (GunController): ShootEvent:FireServer({ shot, ... })
-- where each shot = { originHeadPos, hitPosition, hitInstance }. Silent aim hooks this below.
local ShootEventRemote
pcall(function()
    local rs=game:GetService("ReplicatedStorage")
    local gr=rs:FindFirstChild("GunRemotes") or rs:WaitForChild("GunRemotes",5)
    ShootEventRemote=gr and (gr:FindFirstChild("ShootEvent") or gr:WaitForChild("ShootEvent",5))
end)

-- SILENT AIM (real): hook the game's own shoot remote and rewrite YOUR shot so its hit position +
-- hit instance become the target. No extra shot is sent (that only stacked damage) — your actual
-- bullet is retargeted. We touch ONLY ShootEvent FireServer calls, only while Silent is enabled,
-- and otherwise pass every namecall straight through, so the gun can't break.
do
    local hookmeta=hookmetamethod
    local getnc=getnamecallmethod
    local ischeck=checkcaller
    local wrapcc=newcclosure or function(f) return f end
    if hookmeta and getnc and ShootEventRemote then
        local oldNC
        oldNC=hookmeta(game,"__namecall",wrapcc(function(self,...)
            if F.Aim.Silent and attached and self==ShootEventRemote
               and (not ischeck or not ischeck()) and getnc()=="FireServer" then
                local shots=...
                if type(shots)=="table" then
                    local ok,t=pcall(Aim.getTarget,F.Aim.FOV,F.Aim.WallCheck)
                    if ok and t then
                        for _,e in ipairs(shots) do
                            if type(e)=="table" then e[2]=t.Position; e[3]=t end
                        end
                    end
                end
            end
            return oldNC(self,...)
        end))
        Hub._silentHook=true
    end
end

--== RAGE ===========================================================================
-- Verified live: Prison Life only applies damage when the server sees you (a) holding a gun and
-- (b) CLOSE to the victim (it range/LOS-checks every shot). So rage arms up, teleports ONTO the
-- target, then spams the shoot remote at their head until they drop, then teleports you home.
local GiverRemote, ReloadRemote
pcall(function()
    local rem=game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    GiverRemote=rem and rem:FindFirstChild("GiverPressed")
    ReloadRemote=ShootEventRemote and ShootEventRemote.Parent and ShootEventRemote.Parent:FindFirstChild("FuncReload")
end)
-- reload exactly like the game does (set a session, invoke the reload remote, wait ReloadTime, refill)
local function reloadGun(tool)
    if not (tool and ReloadRemote) then return end
    pcall(function()
        local sess=tick()
        tool:SetAttribute("Local_ReloadSession", sess)
        task.spawn(function() ReloadRemote:InvokeServer() end)
        task.wait(tool:GetAttribute("ReloadTime") or 2)
        tool:SetAttribute("Local_CurrentAmmo", tool:GetAttribute("MaxAmmo") or 30)
        tool:SetAttribute("Local_ReloadSession", 0)
    end)
end
local function heldGun()
    local c=char(); if c then for _,t in ipairs(c:GetChildren()) do if t:IsA("Tool") then return t,true end end end
    local bp=LocalPlayer:FindFirstChild("Backpack")
    if bp then for _,t in ipairs(bp:GetChildren()) do if t:IsA("Tool") then return t,false end end end
    return nil
end
local function findGiver()
    local team=(LocalPlayer.Team and LocalPlayer.Team.Name or ""):lower()
    local want = team:find("guard") and "Remington 870" or "AK-47"
    local fallback
    for _,d in ipairs(Workspace:GetDescendants()) do
        local tn=d:GetAttribute("ToolName")
        if tn then
            local part=d:IsA("BasePart") and d or d:FindFirstChildWhichIsA("BasePart",true)
            if part then
                if tn==want then return part end
                local low=tostring(tn):lower()
                if not fallback and (low:find("ak") or low:find("rifle") or low:find("gun") or low:find("pistol") or low:find("m9") or low:find("smg") or low:find("remington")) then fallback=part end
            end
        end
    end
    return fallback
end
-- ensure a gun is equipped; if you have none, grab one from the armory (this also escapes an inmate)
local function armUp()
    local g,equipped=heldGun()
    if g then if not equipped then pcall(function() hum():EquipTool(g) end) end; return true end
    local giver=findGiver(); local r=root()
    if giver and r and GiverRemote then
        local save=r.CFrame
        pcall(function() r.CFrame=CFrame.new(giver.Position+Vector3.new(0,2.5,0)) end)
        task.wait(0.3)
        pcall(function() GiverRemote:FireServer(giver) end)
        pcall(function() if giver.Parent then GiverRemote:FireServer(giver.Parent) end end)
        task.wait(0.3)
        pcall(function() r.CFrame=save end)
        task.wait(0.2)
    end
    g,equipped=heldGun()
    if g then if not equipped then pcall(function() hum():EquipTool(g) end) end; return true end
    return false
end
local raging=false
Hub._raging=function() return raging end
-- kick-safe rage: fire at the gun's REAL fire rate, track ammo, reload before the mag empties, and
-- never overfire. The earlier version sprayed 0.06s / ~78 rounds with no reload, which tripped the
-- anti-exploit (kick) and desynced the ammo counter (broke the weapon). One mag kills easily.
local function doRage(target)
    if raging or not (target and target.Parent) or not ShootEventRemote then return end
    raging=true
    task.spawn(function()
        pcall(function()
            local r=root(); if not r then raging=false; return end
            local home=r.CFrame
            if not armUp() then raging=false; return end
            task.wait(0.15)
            local tool=char() and char():FindFirstChildOfClass("Tool")
            if not tool then raging=false; return end
            local fireRate=tool:GetAttribute("FireRate") or 0.12
            local interval=math.max(fireRate,0.09)+0.02      -- stay at/above the legit cadence
            local maxAmmo=tool:GetAttribute("MaxAmmo") or 20
            local ammo=tool:GetAttribute("Local_CurrentAmmo") or maxAmmo
            if ammo<12 then reloadGun(tool) end               -- top up first if the mag is low
            local tc=target.Character
            local troot=tc and (tc:FindFirstChild("HumanoidRootPart") or tc:FindFirstChild("Torso"))
            local thum=tc and tc:FindFirstChildOfClass("Humanoid")
            if not (troot and thum and thum.Health>0) then raging=false; return end
            tweenTP(troot.CFrame*CFrame.new(0,0,3.2), 0.2)    -- smooth blink behind them
            task.wait(0.08)
            local fired=0
            while thum and thum.Parent and thum.Health>0 and fired<28 do
                local thead=tc and tc:FindFirstChild("Head"); if not thead then break end
                local mh=char() and char():FindFirstChild("Head")
                local o=(mh and mh.Position) or thead.Position
                pcall(function() ShootEventRemote:FireServer({ { o, thead.Position, thead } }) end)
                fired=fired+1
                local left=(tool:GetAttribute("Local_CurrentAmmo") or maxAmmo)-1
                pcall(function() tool:SetAttribute("Local_CurrentAmmo", left) end)
                if left<=1 then reloadGun(tool) end            -- reload before it hits zero
                task.wait(interval)
                local ntr=tc and (tc:FindFirstChild("HumanoidRootPart") or tc:FindFirstChild("Torso"))
                local rr=root()
                if ntr and rr and (rr.Position-ntr.Position).Magnitude>9 then tweenTP(ntr.CFrame*CFrame.new(0,0,3.2),0.12) end  -- restick to a runner
            end
            tweenTP(home, 0.2)                                 -- glide back
        end)
        raging=false
    end)
end
Hub._rage=doRage

--== SERVER-SIDE INVIS (decoy method) ===============================================
-- You control an invisible client-only CLONE while the server keeps your real body where it was —
-- so OTHER players stop seeing you move (they see a frozen copy at the spot you toggled it on). In a
-- FilteringEnabled game this is the only way others lose sight of you while you stay alive & in
-- control: plain Transparency never replicates, and detaching your body kills the Humanoid (tested).
local invisState
local function applyServerInvis(on)
    pcall(function()
        if on then
            if invisState then return end
            local realCh=LocalPlayer.Character
            local h=realCh and realCh:FindFirstChildOfClass("Humanoid")
            local hrp=realCh and realCh:FindFirstChild("HumanoidRootPart")
            if not (realCh and h and hrp) then return end
            local savedCF=hrp.CFrame
            realCh.Archivable=true
            local clone=realCh:Clone()
            realCh.Archivable=false
            clone.Parent=Workspace
            local ch2=clone:FindFirstChild("HumanoidRootPart")
            if ch2 then ch2.CFrame=savedCF end
            LocalPlayer.Character=clone
            local h2=clone:FindFirstChildOfClass("Humanoid")
            if h2 then cam().CameraSubject=h2 end
            invisState={clone=clone,real=realCh}
        else
            if not invisState then return end
            local clone=invisState.clone; local realCh=invisState.real; invisState=nil
            local dest
            local ch2=clone and clone:FindFirstChild("HumanoidRootPart")
            if ch2 then dest=ch2.CFrame end
            if realCh and realCh.Parent then
                LocalPlayer.Character=realCh
                local rh=realCh:FindFirstChild("HumanoidRootPart")
                if rh and dest then rh.CFrame=dest end
                local rhh=realCh:FindFirstChildOfClass("Humanoid")
                if rhh then cam().CameraSubject=rhh end
            end
            if clone then clone:Destroy() end
        end
    end)
end
Hub._serverInvis=applyServerInvis

local BONES={ {"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},{"Torso","Left Leg"},{"Torso","Right Leg"} }
local ESP = {}
do
    -- some executors expose a broken/partial Drawing; verify it actually CONSTRUCTS before trusting
    -- it, else fall back to Highlight so ESP renders on ANY executor (this is the cross-exec fix).
    local hasDraw=false
    if Drawing and Drawing.new then
        local ok,probe=pcall(Drawing.new,"Square")
        if ok and probe then hasDraw=true; pcall(function() probe:Remove() end) end
    end
    local host=CoreGui
    if gethui then local ok,h=pcall(gethui); if ok and h then host=h end end
    host=host or LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local pool={}
    local function nd(k,pr) local d=Drawing.new(k); for a,b in pairs(pr) do d[a]=b end; return d end
    local function build(p)
        if hasDraw then
            local ok=pcall(function()
                local bones={}; for i=1,#BONES do bones[i]=nd("Line",{Thickness=1,Color=Color3.new(1,1,1)}) end
                pool[p]={ box=nd("Square",{Thickness=1,Filled=false,Color=Color3.new(1,1,1)}),
                    boxo=nd("Square",{Thickness=3,Filled=false,Color=Color3.new(0,0,0)}),
                    name=nd("Text",{Size=13,Center=true,Outline=true,Color=Color3.new(1,1,1)}),
                    dist=nd("Text",{Size=12,Center=true,Outline=true,Color=Color3.fromRGB(190,190,190)}),
                    trac=nd("Line",{Thickness=1,Color=Color3.fromRGB(255,95,95)}),
                    hpbg=nd("Square",{Thickness=1,Filled=true,Color=Color3.fromRGB(15,15,15)}),
                    hp=nd("Square",{Thickness=1,Filled=true,Color=Color3.fromRGB(90,230,150)}), bones=bones }
            end)
            if ok and pool[p] then return end
            hasDraw=false; pool[p]=nil  -- Drawing threw mid-build → drop to Highlight for everyone
        end
        local ok2,hl=pcall(Instance.new,"Highlight")
        if ok2 and hl then
            hl.FillTransparency=0.55; hl.OutlineColor=Color3.fromRGB(255,95,95)
            hl.FillColor=Color3.fromRGB(255,95,95); hl.Adornee=p.Character
            pcall(function() hl.Parent=host end); pool[p]={hl=hl}
        end
    end
    local function hide(o)
        if o.hl then o.hl.Adornee=nil return end
        o.box.Visible=false; o.boxo.Visible=false; o.name.Visible=false; o.dist.Visible=false
        o.trac.Visible=false; o.hpbg.Visible=false; o.hp.Visible=false
        for _,ln in ipairs(o.bones) do ln.Visible=false end
    end
    function ESP.clear(p) local o=pool[p]; if not o then return end
        if o.hl then o.hl:Destroy() else
            for _,d in ipairs({o.box,o.boxo,o.name,o.dist,o.trac,o.hpbg,o.hp}) do pcall(function() d:Remove() end) end
            for _,ln in ipairs(o.bones) do pcall(function() ln:Remove() end) end
        end; pool[p]=nil end
    function ESP.render()
        if not attached then for _,p in ipairs(Players:GetPlayers()) do local o=pool[p]; if o then hide(o) end end return end
        for _,p in ipairs(Players:GetPlayers()) do if p~=LocalPlayer then
            if not pool[p] then build(p) end
            local o=pool[p]; local ok,c,h=alive(p)
            local hrp=ok and (c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso"))
            if not (F.ESP.On and hrp) then if o then hide(o) end
            elseif o.hl then o.hl.Adornee=c
            else
                local enemy=isEnemy(p)
                if F.ESP.EnemiesOnly and not enemy then hide(o); continue end
                local col=enemy and Color3.fromRGB(255,95,95) or Color3.fromRGB(90,230,150)
                local head=c:FindFirstChild("Head")
                local top=cam():WorldToViewportPoint((head and head.Position or hrp.Position)+Vector3.new(0,0.6,0))
                local bot=cam():WorldToViewportPoint(hrp.Position-Vector3.new(0,3.2,0))
                if top.Z>0 then
                    local h2=math.abs(top.Y-bot.Y); local w=h2*0.62; local x,y=top.X-w/2,top.Y
                    o.box.Visible=F.ESP.Box; o.boxo.Visible=F.ESP.Box; o.box.Filled=F.ESP.Filled; o.box.Transparency=F.ESP.Filled and 0.35 or 1
                    o.box.Size=Vector2.new(w,h2); o.box.Position=Vector2.new(x,y); o.boxo.Size=o.box.Size; o.boxo.Position=o.box.Position; o.box.Color=col
                    o.name.Visible=F.ESP.Name; o.name.Text=p.Name; o.name.Color=col; o.name.Position=Vector2.new(top.X,y-15)
                    o.dist.Visible=F.ESP.Dist; o.dist.Text=math.floor((cam().CFrame.Position-hrp.Position).Magnitude).."m"; o.dist.Position=Vector2.new(top.X,y+h2+1)
                    local hb=F.ESP.Health and h; o.hpbg.Visible=hb; o.hp.Visible=hb
                    if hb then local r=math.clamp(h.Health/math.max(h.MaxHealth,1),0,1)
                        o.hpbg.Size=Vector2.new(3,h2); o.hpbg.Position=Vector2.new(x-6,y)
                        o.hp.Size=Vector2.new(3,h2*r); o.hp.Position=Vector2.new(x-6,y+h2*(1-r))
                        o.hp.Color=Color3.fromRGB(math.floor(255*(1-r)),math.floor(220*r+35),80) end
                    o.trac.Visible=F.ESP.Tracer
                    if F.ESP.Tracer then o.trac.Color=col; local vp=cam().ViewportSize; o.trac.From=Vector2.new(vp.X/2,vp.Y); o.trac.To=Vector2.new(top.X,y+h2) end
                else
                    o.box.Visible=false; o.boxo.Visible=false; o.name.Visible=false; o.dist.Visible=false; o.trac.Visible=false; o.hpbg.Visible=false; o.hp.Visible=false
                end
                if F.ESP.Skeleton then
                    for i,pair in ipairs(BONES) do
                        local pa=c:FindFirstChild(pair[1]); local pb=c:FindFirstChild(pair[2]); local ln=o.bones[i]
                        if pa and pb then
                            local sa=cam():WorldToViewportPoint(pa.Position); local sb=cam():WorldToViewportPoint(pb.Position)
                            if sa.Z>0 and sb.Z>0 then ln.Visible=true; ln.Color=col; ln.From=Vector2.new(sa.X,sa.Y); ln.To=Vector2.new(sb.X,sb.Y)
                            else ln.Visible=false end
                        else ln.Visible=false end
                    end
                else for _,ln in ipairs(o.bones) do ln.Visible=false end end
            end
        end end
    end
    function ESP.destroy() for p in pairs(pool) do ESP.clear(p) end end
end

local function applyMovement(dt)
    local h,r=hum(),root()
    if h then
        if F.Mov.Speed then h.WalkSpeed=F.Mov.SpeedV end
        if F.Mov.JumpOn then h.UseJumpPower=true; h.JumpPower=F.Mov.JumpV end
    end
    if F.Mov.Fly and r then
        local c=cam().CFrame; local d=Vector3.zero
        if key(Enum.KeyCode.W) then d+=c.LookVector end
        if key(Enum.KeyCode.S) then d-=c.LookVector end
        if key(Enum.KeyCode.A) then d-=c.RightVector end
        if key(Enum.KeyCode.D) then d+=c.RightVector end
        if key(Enum.KeyCode.Space) then d+=Vector3.new(0,1,0) end
        if key(Enum.KeyCode.LeftControl) then d-=Vector3.new(0,1,0) end
        if d.Magnitude>0 then r.CFrame=r.CFrame+d.Unit*(F.Mov.FlyV*50)*dt end
        r.AssemblyLinearVelocity=Vector3.zero
    end
end
local noclipConns={}
local function clearNoclip() for _,c in ipairs(noclipConns) do pcall(function() c:Disconnect() end) end; noclipConns={} end
local function applyNoclip()
    clearNoclip(); local c=char(); if not c then return end
    for _,v in ipairs(c:GetDescendants()) do
        if v:IsA("BasePart") then v.CanCollide=false
            noclipConns[#noclipConns+1]=v:GetPropertyChangedSignal("CanCollide"):Connect(function()
                if F.Mov.Noclip and v.CanCollide then v.CanCollide=false end end)
        end
    end
end
local function stopNoclip()
    clearNoclip(); local c=char()
    if c then for _,v in ipairs(c:GetDescendants()) do if v:IsA("BasePart") and v.Name~="HumanoidRootPart" then v.CanCollide=true end end end
end

-- local invisibility: hides YOUR body on your own client. Transparency changes don't replicate,
-- so this is client-side only (enemies still see you). Fully reversible — restores original values.
local invisSaved
local function applyInvis(on)
    local c=char(); if not c then return end
    if on then
        invisSaved=invisSaved or {}
        for _,d in ipairs(c:GetDescendants()) do
            if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
                if invisSaved[d]==nil then invisSaved[d]=d.Transparency end
                d.Transparency=1
            end
        end
    else
        if invisSaved then for d,t in pairs(invisSaved) do if d and d.Parent then pcall(function() d.Transparency=t end) end end end
        invisSaved=nil
    end
end

local fbState
local function fullbright(on)
    if on then
        fbState=fbState or {b=Lighting.Brightness,ct=Lighting.ClockTime,fe=Lighting.FogEnd,am=Lighting.Ambient,oa=Lighting.OutdoorAmbient,gs=Lighting.GlobalShadows}
        Lighting.Brightness=2; Lighting.ClockTime=14; Lighting.FogEnd=1e9
        Lighting.Ambient=Color3.fromRGB(178,178,178); Lighting.OutdoorAmbient=Color3.fromRGB(178,178,178); Lighting.GlobalShadows=false
    elseif fbState then
        Lighting.Brightness=fbState.b; Lighting.ClockTime=fbState.ct; Lighting.FogEnd=fbState.fe
        Lighting.Ambient=fbState.am; Lighting.OutdoorAmbient=fbState.oa; Lighting.GlobalShadows=fbState.gs
    end
end

local plTarget, plFollow, spectating, spectateTarget = nil, false, false, nil
local function stopSpectate() spectating=false; spectateTarget=nil; local mh=hum(); if mh then pcall(function() cam().CameraSubject=mh end) end end

--== theme + helpers ==--
local T = {
    bg=Color3.fromRGB(22,22,25), title=Color3.fromRGB(16,16,19), panel=Color3.fromRGB(29,29,33),
    item=Color3.fromRGB(37,37,42), itemH=Color3.fromRGB(49,49,55),
    line=Color3.fromRGB(58,58,64), text=Color3.fromRGB(232,232,236), sub=Color3.fromRGB(148,148,155),
    accent=Color3.fromRGB(224,64,64), off=Color3.fromRGB(50,50,56), green=Color3.fromRGB(120,210,140),
}
local FONT=Enum.Font.Gotham
local BOLD=Enum.Font.GothamBold
local function make(cls,pr,par) local o=Instance.new(cls); for k,v in pairs(pr) do o[k]=v end; o.Parent=par; return o end
local function corner(o,r) return make("UICorner",{CornerRadius=UDim.new(0,r or 4)},o) end
local function stroke(o,col,t) return make("UIStroke",{Color=col or T.line,Thickness=t or 1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},o) end
local function tw(o,dur,props,style,dir)
    local ok,t=pcall(function()
        return Tween:Create(o,TweenInfo.new(dur or 0.15,style or Enum.EasingStyle.Quad,dir or Enum.EasingDirection.Out),props)
    end)
    if ok and t then t:Play() end; return t
end

local accentObjs={}     -- {o=inst, p=prop}
local accentRings={}     -- {st=stroke, get=fn}  (recolor only when active)
local fovCircle
local function reg(o,prop) accentObjs[#accentObjs+1]={o=o,p=prop or "BackgroundColor3"}; return o end
local function setAccent(col)
    T.accent=col
    for _,e in ipairs(accentObjs) do pcall(function() if e.o and e.o.Parent then e.o[e.p]=col end end) end
    for _,e in ipairs(accentRings) do pcall(function() e.st.Color=e.get() and col or T.line end) end
    if fovCircle then pcall(function() fovCircle.Color=col end) end
end

local gui=make("ScreenGui",{Name="syntax_"..tostring(math.random(1e5,1e6)),ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},(gethui and gethui()) or CoreGui)
pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)

local WIN_W,WIN_H=600,470
local win=make("Frame",{Size=UDim2.fromOffset(WIN_W,WIN_H),Position=UDim2.new(0.5,-WIN_W/2,0.5,-WIN_H/2),BackgroundColor3=T.bg,BorderSizePixel=0,ClipsDescendants=true},gui)
corner(win,7); stroke(win,T.line,1)
local curW,curH=WIN_W,WIN_H

-- resize grip (bottom-right). Layout is mostly scale-based, so children reflow as the window grows.
local rez=make("Frame",{Size=UDim2.fromOffset(14,14),Position=UDim2.new(1,-16,1,-16),BackgroundColor3=T.line,BackgroundTransparency=0.25,BorderSizePixel=0,ZIndex=60,Active=true},win); corner(rez,3)
do local rz,rs,rsz
    rez.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then rz=true; rs=Vector2.new(i.Position.X,i.Position.Y); rsz=win.AbsoluteSize end end)
    bind(UIS.InputChanged,function(i) if rz and i.UserInputType==Enum.UserInputType.MouseMovement then
        local d=Vector2.new(i.Position.X,i.Position.Y)-rs
        curW=math.clamp(math.floor(rsz.X+d.X),430,1000); curH=math.clamp(math.floor(rsz.Y+d.Y),300,760)
        win.Size=UDim2.fromOffset(curW,curH) end end)
    bind(UIS.InputEnded,function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then rz=false end end)
end

--== falling boxes: render OVER content as a faint overlay so the fall is always visible
--   (at ZIndex 0 they were hidden behind every opaque panel — that's why they looked frozen). ==--
local bgHost=make("Frame",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0,ZIndex=8},win)
local boxes={}
for i=1,22 do
    local sz=math.random(7,20)
    local b=make("Frame",{Size=UDim2.fromOffset(sz,sz),Position=UDim2.fromOffset(math.random(0,WIN_W),math.random(-WIN_H,WIN_H)),BackgroundColor3=Color3.fromRGB(120,120,132),BackgroundTransparency=0.86,BorderSizePixel=0,ZIndex=8,Rotation=math.random(0,45)},bgHost)
    corner(b,3)
    boxes[i]={f=b,spd=math.random(16,46),x=b.Position.X.Offset,y=b.Position.Y.Offset}
end

local titleBar=make("Frame",{Size=UDim2.new(1,0,0,34),BackgroundColor3=T.title,BorderSizePixel=0},win)
do
    local okId,id
    if isfile and isfile("syntax_logo.png") and getcustomasset then okId,id=pcall(getcustomasset,"syntax_logo.png") end
    if okId and id then make("ImageLabel",{Size=UDim2.fromOffset(26,26),Position=UDim2.fromOffset(9,4),BackgroundTransparency=1,Image=id},titleBar)
    else local mark=reg(make("Frame",{Size=UDim2.fromOffset(14,14),Position=UDim2.fromOffset(14,10),BackgroundColor3=T.accent,BorderSizePixel=0},titleBar)); corner(mark,3) end
end
make("TextLabel",{Size=UDim2.fromOffset(160,34),Position=UDim2.fromOffset(36,0),BackgroundTransparency=1,Font=BOLD,Text="syntax",TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=16},titleBar)
make("TextLabel",{Size=UDim2.fromOffset(160,34),Position=UDim2.fromOffset(102,1),BackgroundTransparency=1,Font=FONT,Text="·  <3",TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},titleBar)
local closeB=make("TextButton",{Size=UDim2.fromOffset(26,20),Position=UDim2.new(1,-32,0,7),BackgroundColor3=T.item,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text="X",TextColor3=T.sub,TextSize=12},titleBar); corner(closeB,4)
local minB=make("TextButton",{Size=UDim2.fromOffset(26,20),Position=UDim2.new(1,-62,0,7),BackgroundColor3=T.item,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text="—",TextColor3=T.sub,TextSize=12},titleBar); corner(minB,4)
closeB.MouseEnter:Connect(function() tw(closeB,0.12,{BackgroundColor3=Color3.fromRGB(180,55,55)}) end)
closeB.MouseLeave:Connect(function() tw(closeB,0.12,{BackgroundColor3=T.item}) end)
minB.MouseEnter:Connect(function() tw(minB,0.12,{BackgroundColor3=T.itemH}) end)
minB.MouseLeave:Connect(function() tw(minB,0.12,{BackgroundColor3=T.item}) end)

do local drag,ds,sp
    bind(titleBar.InputBegan,function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true;ds=i.Position;sp=win.Position end end)
    bind(UIS.InputChanged,function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then
        local d=i.Position-ds; win.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y) end end)
    bind(UIS.InputEnded,function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
end

local tabBar=make("Frame",{Size=UDim2.new(1,0,0,30),Position=UDim2.fromOffset(0,34),BackgroundColor3=T.title,BorderSizePixel=0},win)
make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,VerticalAlignment=Enum.VerticalAlignment.Center,SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,2)},tabBar)
make("UIPadding",{PaddingLeft=UDim.new(0,8)},tabBar)
make("Frame",{Size=UDim2.new(1,0,0,1),Position=UDim2.fromOffset(0,64),BackgroundColor3=T.line,BorderSizePixel=0},win)
local underline=reg(make("Frame",{Size=UDim2.fromOffset(0,2),Position=UDim2.fromOffset(0,62),BackgroundColor3=T.accent,BorderSizePixel=0,ZIndex=3},win))

local body=make("Frame",{Size=UDim2.new(1,0,1,-99),Position=UDim2.fromOffset(0,65),BackgroundTransparency=1},win)

local pages,tabBtns={},{}
local function moveUnderline(btn,instant)
    local x=btn.AbsolutePosition.X - win.AbsolutePosition.X
    local w=btn.AbsoluteSize.X
    if instant then underline.Position=UDim2.fromOffset(x,62); underline.Size=UDim2.fromOffset(w,2)
    else tw(underline,0.2,{Position=UDim2.fromOffset(x,62),Size=UDim2.fromOffset(w,2)},Enum.EasingStyle.Quart) end
end
local function selectTab(n)
    for k,pg in pairs(pages) do pg.frame.Visible=(k==n) end
    for k,b in pairs(tabBtns) do b.lbl.TextColor3=(k==n) and T.text or T.sub end
    moveUnderline(tabBtns[n].lbl)
end
local function addTab(n)
    local b=make("TextButton",{AutomaticSize=Enum.AutomaticSize.X,Size=UDim2.new(0,0,1,0),BackgroundTransparency=1,AutoButtonColor=false,Font=FONT,Text=n,TextColor3=T.sub,TextSize=12},tabBar)
    make("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10)},b)
    b.MouseEnter:Connect(function() if tabBtns[n] and tabBtns[n].lbl.TextColor3~=T.text then tw(b,0.12,{TextColor3=T.text}) end end)
    b.MouseLeave:Connect(function()
        local active=false; for k,x in pairs(tabBtns) do if x.lbl==b then active=(pages[k].frame.Visible) end end
        if not active then tw(b,0.12,{TextColor3=T.sub}) end end)
    local frame=make("Frame",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Visible=false},body)
    local function col(px)
        local c=make("ScrollingFrame",{Position=UDim2.new(px,px==0 and 8 or 4,0,8),Size=UDim2.new(0.5,-12,1,-16),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=T.line,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y},frame)
        make("UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},c)
        return c
    end
    local pg={frame=frame,left=col(0),right=col(0.5)}
    tabBtns[n]={lbl=b}; pages[n]=pg
    b.MouseButton1Click:Connect(function() selectTab(n) end)
    return pg
end

local function section(par,title)
    local s=make("Frame",{Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundColor3=T.panel,BorderSizePixel=0},par); corner(s,5); stroke(s,T.line,1)
    make("UIPadding",{PaddingTop=UDim.new(0,8),PaddingBottom=UDim.new(0,10),PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10)},s)
    make("UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},s)
    reg(make("TextLabel",{Size=UDim2.new(1,0,0,16),BackgroundTransparency=1,Font=BOLD,Text=title,TextColor3=T.accent,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12,LayoutOrder=-1},s),"TextColor3")
    return s
end

--== footer (status only — features are always live, no attach step) ==--
local footer=make("Frame",{Size=UDim2.new(1,0,0,34),Position=UDim2.new(0,0,1,-34),BackgroundColor3=T.title,BorderSizePixel=0},win)
make("Frame",{Size=UDim2.new(1,0,0,1),BackgroundColor3=T.line,BorderSizePixel=0},footer)
local dot=make("Frame",{Size=UDim2.fromOffset(8,8),Position=UDim2.fromOffset(16,13),BackgroundColor3=T.green,BorderSizePixel=0},footer); corner(dot,4)
make("TextLabel",{Size=UDim2.new(1,-24,1,0),Position=UDim2.fromOffset(32,0),BackgroundTransparency=1,Font=FONT,Text=LocalPlayer.Name.."   ·   Prison Life",TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},footer)

--== controls ==--
local function toggle(p,text,get,set)
    local r=make("Frame",{Size=UDim2.new(1,0,0,22),BackgroundTransparency=1},p)
    local ring=make("Frame",{Size=UDim2.fromOffset(15,15),Position=UDim2.new(0,0,0.5,-7),BackgroundTransparency=1,BorderSizePixel=0},r); corner(ring,8)
    local st=stroke(ring,get() and T.accent or T.line,1)
    accentRings[#accentRings+1]={st=st,get=get}
    local dt=reg(make("Frame",{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),Size=UDim2.fromOffset(get() and 7 or 0,get() and 7 or 0),BackgroundColor3=T.accent,BackgroundTransparency=get() and 0 or 1,BorderSizePixel=0,Visible=get()},ring)); corner(dt,4)
    make("TextLabel",{Size=UDim2.new(1,-24,1,0),Position=UDim2.fromOffset(23,0),BackgroundTransparency=1,Font=FONT,Text=text,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},r)
    local btn=make("TextButton",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Text=""},r)
    btn.MouseButton1Click:Connect(function()
        local v=not get(); set(v); st.Color=v and T.accent or T.line
        if v then dt.Visible=true; tw(dt,0.16,{Size=UDim2.fromOffset(7,7),BackgroundTransparency=0},Enum.EasingStyle.Back)
        else tw(dt,0.12,{Size=UDim2.fromOffset(0,0),BackgroundTransparency=1}); task.delay(0.14,function() if not get() then dt.Visible=false end end) end
    end)
end
local function slider(p,text,mn,mx,get,set)
    local r=make("Frame",{Size=UDim2.new(1,0,0,38),BackgroundTransparency=1},p)
    make("TextLabel",{Size=UDim2.new(1,-60,0,16),Position=UDim2.fromOffset(0,1),BackgroundTransparency=1,Font=FONT,Text=text,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},r)
    local val=reg(make("TextLabel",{Size=UDim2.new(0,58,0,16),Position=UDim2.new(1,-58,0,1),BackgroundTransparency=1,Font=FONT,Text=tostring(get()),TextColor3=T.accent,TextXAlignment=Enum.TextXAlignment.Right,TextSize=12},r),"TextColor3")
    local track=make("Frame",{Size=UDim2.new(1,0,0,6),Position=UDim2.fromOffset(0,24),BackgroundColor3=T.off,BorderSizePixel=0},r); corner(track,3)
    local fill=reg(make("Frame",{Size=UDim2.new((get()-mn)/(mx-mn),0,1,0),BackgroundColor3=T.accent,BorderSizePixel=0},track)); corner(fill,3)
    local function setX(px,anim) local a=math.clamp((px-track.AbsolutePosition.X)/track.AbsoluteSize.X,0,1)
        local v=math.floor((mn+(mx-mn)*a)*100)/100; val.Text=tostring(v); set(v)
        if anim then tw(fill,0.08,{Size=UDim2.new(a,0,1,0)}) else fill.Size=UDim2.new(a,0,1,0) end end
    local drag=false
    track.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true;setX(i.Position.X,true) end end)
    bind(UIS.InputChanged,function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then setX(i.Position.X) end end)
    bind(UIS.InputEnded,function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
end
local function button(p,text,cb)
    local b=make("TextButton",{Size=UDim2.new(1,0,0,26),BackgroundColor3=T.item,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text=text,TextColor3=T.text,TextSize=12},p); corner(b,4); stroke(b,T.line,1)
    b.MouseButton1Click:Connect(cb); b.MouseEnter:Connect(function() tw(b,0.12,{BackgroundColor3=T.itemH}) end); b.MouseLeave:Connect(function() tw(b,0.12,{BackgroundColor3=T.item}) end)
    return b
end
local function label(p,text) return make("TextLabel",{Size=UDim2.new(1,0,0,15),BackgroundTransparency=1,Font=FONT,Text=text,TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=11,TextWrapped=true},p) end

--== real dropdown (floating, animated) ==--
local activeDrop,activeDropBtn=nil,nil
local function closeDrop()
    if activeDrop then
        local m=activeDrop; activeDrop=nil; activeDropBtn=nil
        tw(m,0.12,{Size=UDim2.fromOffset(m.AbsoluteSize.X,0)})
        task.delay(0.14,function() if m and m.Parent then m:Destroy() end end)
    end
end
local function dropdown(p,labelText,getOptions,getCurrent,onSet)
    local r=make("Frame",{Size=UDim2.new(1,0,0,24),BackgroundTransparency=1},p)
    make("TextLabel",{Size=UDim2.new(0.42,-4,1,0),BackgroundTransparency=1,Font=FONT,Text=labelText,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},r)
    local btn=make("TextButton",{Size=UDim2.new(0.58,0,0,22),Position=UDim2.new(0.42,4,0.5,-11),BackgroundColor3=T.item,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text=getCurrent().."   ▼",TextColor3=T.accent,TextSize=11},r); corner(btn,4); stroke(btn,T.line,1)
    reg(btn,"TextColor3")
    local function label2() btn.Text=getCurrent().."   ▼" end
    btn.MouseEnter:Connect(function() tw(btn,0.12,{BackgroundColor3=T.itemH}) end)
    btn.MouseLeave:Connect(function() tw(btn,0.12,{BackgroundColor3=T.item}) end)
    btn.MouseButton1Click:Connect(function()
        if activeDropBtn==btn then closeDrop(); return end
        closeDrop()
        local opts=getOptions(); local n=math.max(#opts,1)
        local rel=btn.AbsolutePosition - win.AbsolutePosition
        local w=btn.AbsoluteSize.X; local rowH=22; local full=math.min(n*rowH+4,158)
        local menu=make("Frame",{Size=UDim2.fromOffset(w,0),Position=UDim2.fromOffset(rel.X,rel.Y+btn.AbsoluteSize.Y+2),BackgroundColor3=T.panel,BorderSizePixel=0,ClipsDescendants=true,ZIndex=40},win); corner(menu,4); stroke(menu,T.line,1)
        local sc=make("ScrollingFrame",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=T.line,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=40},menu)
        make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder},sc)
        make("UIPadding",{PaddingTop=UDim.new(0,2),PaddingBottom=UDim.new(0,2)},sc)
        for i,opt in ipairs(opts) do
            local row=make("TextButton",{Size=UDim2.new(1,0,0,rowH),BackgroundColor3=T.panel,BackgroundTransparency=1,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text="  "..opt,TextColor3=(opt==getCurrent()) and T.accent or T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12,ZIndex=41},sc)
            row.MouseEnter:Connect(function() row.BackgroundTransparency=0; row.BackgroundColor3=T.itemH end)
            row.MouseLeave:Connect(function() row.BackgroundTransparency=1 end)
            row.MouseButton1Click:Connect(function() onSet(i,opt); label2(); closeDrop() end)
        end
        activeDrop=menu; activeDropBtn=btn
        tw(menu,0.14,{Size=UDim2.fromOffset(w,full)},Enum.EasingStyle.Quart)
    end)
    return {refresh=label2,btn=btn}
end
bind(UIS.InputBegan,function(i)
    if i.UserInputType~=Enum.UserInputType.MouseButton1 or not activeDrop then return end
    local p=Vector2.new(i.Position.X,i.Position.Y)
    local function inside(o) local ap,as=o.AbsolutePosition,o.AbsoluteSize; return p.X>=ap.X and p.X<=ap.X+as.X and p.Y>=ap.Y and p.Y<=ap.Y+as.Y end
    if not (inside(activeDrop) or (activeDropBtn and inside(activeDropBtn))) then closeDrop() end
end)

--== DASHBOARD ==--
local updateDash,dashRender
do
    local pg=addTab("Dashboard")
    local sChar=section(pg.left,"Character  ·  ESP preview")
    label(sChar,"right-click + drag to rotate")
    local wrap=make("Frame",{Size=UDim2.new(1,0,0,210),BackgroundTransparency=1,ClipsDescendants=true},sChar); corner(wrap,5)
    local vpf=make("ViewportFrame",{Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.fromRGB(30,30,35),BorderSizePixel=0,Ambient=Color3.fromRGB(245,245,250),LightColor=Color3.fromRGB(255,255,255),LightDirection=Vector3.new(-0.3,-0.7,-0.55),ZIndex=1},wrap); corner(vpf,5)
    local vpcam=make("Camera",{FieldOfView=50},vpf); vpf.CurrentCamera=vpcam
    local espCol=Color3.fromRGB(255,95,95)
    -- 2D ESP overlay PROJECTED onto the avatar (matches what real players get); tracer intentionally omitted
    local eBox=make("Frame",{BackgroundColor3=espCol,BackgroundTransparency=1,BorderSizePixel=0,ZIndex=4,Visible=false},wrap); stroke(eBox,espCol,1)
    local eName=make("TextLabel",{BackgroundTransparency=1,Font=FONT,Text=LocalPlayer.Name,TextColor3=espCol,TextXAlignment=Enum.TextXAlignment.Center,TextSize=12,ZIndex=4,Visible=false},wrap)
    local eDist=make("TextLabel",{BackgroundTransparency=1,Font=FONT,Text="0m",TextColor3=Color3.fromRGB(205,205,205),TextXAlignment=Enum.TextXAlignment.Center,TextSize=11,ZIndex=4,Visible=false},wrap)
    local eHpBg=make("Frame",{BackgroundColor3=Color3.fromRGB(15,15,15),BorderSizePixel=0,ZIndex=4,Visible=false},wrap)
    local eHp=make("Frame",{Size=UDim2.new(1,0,1,0),BackgroundColor3=T.green,BorderSizePixel=0,ZIndex=4},eHpBg)
    local eBones={}; for i=1,5 do eBones[i]=make("Frame",{AnchorPoint=Vector2.new(0.5,0.5),BackgroundColor3=espCol,BorderSizePixel=0,ZIndex=4,Visible=false},wrap) end
    make("TextLabel",{Size=UDim2.new(0,70,0,12),Position=UDim2.new(1,-74,0,5),BackgroundTransparency=1,Font=FONT,Text="tracers off",TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Right,TextSize=10,ZIndex=4},wrap)

    local avatar; local building=false
    local BONE_PAIRS={ {"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},{"Torso","Left Leg"},{"Torso","Right Leg"} }
    local base=CFrame.Angles(0,math.pi,0)
    local function buildAvatar()
        if building then return end
        building=true
        task.spawn(function()
            local model
            local ok,desc=pcall(function() return Players:GetHumanoidDescriptionFromUserId(LocalPlayer.UserId) end)
            if ok and desc then local ok2,m=pcall(function() return Players:CreateHumanoidModelFromDescription(desc,Enum.HumanoidRigType.R6) end)
                if ok2 then model=m end end
            if not model then local c=char()
                if c then local ok3,cl=pcall(function() local w=c.Archivable; c.Archivable=true; local x=c:Clone(); c.Archivable=w; return x end); if ok3 then model=cl end end end
            if not model then building=false; return end
            for _,d in ipairs(model:GetDescendants()) do
                if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Sound") or d:IsA("Tool") then pcall(function() d:Destroy() end) end end
            local hn=model:FindFirstChildOfClass("Humanoid"); if hn then pcall(function() hn.DisplayDistanceType=Enum.HumanoidDisplayDistanceType.None end) end
            pcall(function() model:PivotTo(base) end)
            for _,d in ipairs(model:GetDescendants()) do if d:IsA("BasePart") then d.Anchored=true; d.CastShadow=false end end
            if avatar then avatar:Destroy() end
            model.Parent=vpf; avatar=model
            building=false
        end)
    end
    -- project a world point into wrap-local pixels (ViewportFrame has no WorldToViewportPoint)
    local function project(w)
        local vs=vpf.AbsoluteSize; if vs.Y<=0 then return nil end
        local rel=vpcam.CFrame:PointToObjectSpace(w); local depth=-rel.Z
        if depth<=0.05 then return nil end
        local th=math.tan(math.rad(vpcam.FieldOfView)/2); local asp=vs.X/vs.Y
        local x=(rel.X/(depth*th*asp)*0.5+0.5)*vs.X
        local y=(1-(rel.Y/(depth*th)*0.5+0.5))*vs.Y
        return Vector2.new(x,y)
    end
    local function updateEsp()
        local m=avatar
        if not m then eBox.Visible=false;eName.Visible=false;eDist.Visible=false;eHpBg.Visible=false; for _,l in ipairs(eBones) do l.Visible=false end; return end
        local head=m:FindFirstChild("Head"); local hrp=m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Torso")
        local top=hrp and project((head and head.Position or hrp.Position)+Vector3.new(0,0.7,0))
        local bot=hrp and project(hrp.Position-Vector3.new(0,3.0,0))
        if top and bot then
            local h2=math.abs(top.Y-bot.Y); local w=h2*0.62; local x=top.X-w/2; local y=math.min(top.Y,bot.Y)
            eBox.Visible=F.ESP.Box; eBox.BackgroundTransparency=F.ESP.Filled and 0.72 or 1
            eBox.Size=UDim2.fromOffset(w,h2); eBox.Position=UDim2.fromOffset(x,y)
            eName.Visible=F.ESP.Name; eName.Size=UDim2.fromOffset(140,14); eName.Position=UDim2.fromOffset(top.X-70,y-16)
            eDist.Visible=F.ESP.Dist; eDist.Size=UDim2.fromOffset(140,12); eDist.Position=UDim2.fromOffset(top.X-70,y+h2+2)
            eHpBg.Visible=F.ESP.Health; eHpBg.Size=UDim2.fromOffset(3,h2); eHpBg.Position=UDim2.fromOffset(x-5,y)
        else eBox.Visible=false;eName.Visible=false;eDist.Visible=false;eHpBg.Visible=false end
        for i,pr in ipairs(BONE_PAIRS) do local ln=eBones[i]
            local pa=m:FindFirstChild(pr[1]); local pb=m:FindFirstChild(pr[2])
            if F.ESP.Skeleton and pa and pb then local a=project(pa.Position); local b=project(pb.Position)
                if a and b then local d=(a-b).Magnitude
                    ln.Visible=true; ln.Size=UDim2.fromOffset(math.max(d,1),2); ln.Position=UDim2.fromOffset((a.X+b.X)/2,(a.Y+b.Y)/2); ln.Rotation=math.deg(math.atan2(b.Y-a.Y,b.X-a.X))
                else ln.Visible=false end
            else ln.Visible=false end
        end
    end
    -- orbit camera with SMOOTH (lerped) drag
    local yaw,pitch,tYaw,tPitch,dist=0,0,0,0,7.2
    local function updateCam()
        local rot=CFrame.Angles(0,yaw,0)*CFrame.Angles(pitch,0,0); local tgt=Vector3.new(0,-0.4,0)
        vpcam.CFrame=CFrame.lookAt(tgt+rot:VectorToWorldSpace(Vector3.new(0,0,dist)),tgt)
    end
    do local dragging,lastP
        vpf.Active=true
        vpf.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton2 then dragging=true; lastP=Vector2.new(i.Position.X,i.Position.Y) end end)
        vpf.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton2 then dragging=false end end)
        bind(UIS.InputChanged,function(i) if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
            local p=Vector2.new(i.Position.X,i.Position.Y); tYaw-=(p.X-lastP.X)*0.009; tPitch=math.clamp(tPitch-(p.Y-lastP.Y)*0.009,-1.1,1.1); lastP=p end end)
    end
    function dashRender(dt)
        local a=math.clamp(dt*16,0,1)
        yaw=yaw+(tYaw-yaw)*a; pitch=pitch+(tPitch-pitch)*a
        updateCam(); updateEsp()
        if not avatar and not building then buildAvatar() end
    end
    updateCam()

    local sStat=section(pg.right,"Stats")
    make("TextLabel",{Size=UDim2.new(1,0,0,20),BackgroundTransparency=1,Font=BOLD,Text=LocalPlayer.Name,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=15},sStat)
    local teamLbl=make("TextLabel",{Size=UDim2.new(1,0,0,15),BackgroundTransparency=1,Font=FONT,Text="Team:  —",TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},sStat)
    local hpTxt=make("TextLabel",{Size=UDim2.new(1,0,0,14),BackgroundTransparency=1,Font=FONT,Text="HP  —",TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=11},sStat)
    local hpBg=make("Frame",{Size=UDim2.new(1,0,0,8),BackgroundColor3=T.off,BorderSizePixel=0},sStat); corner(hpBg,3)
    local hpFill=make("Frame",{Size=UDim2.new(1,0,1,0),BackgroundColor3=T.green,BorderSizePixel=0},hpBg); corner(hpFill,3)
    local function stat(name)
        local r=make("Frame",{Size=UDim2.new(1,0,0,20),BackgroundTransparency=1},sStat)
        make("TextLabel",{Size=UDim2.new(0.6,0,1,0),BackgroundTransparency=1,Font=FONT,Text=name,TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},r)
        return make("TextLabel",{Size=UDim2.new(0.4,0,1,0),Position=UDim2.new(0.6,0,0,0),BackgroundTransparency=1,Font=BOLD,Text="—",TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Right,TextSize=13},r)
    end
    local sKills=stat("Kills"); local sAllies=stat("Allies alive"); local sEnemies=stat("Enemies alive")
    local sOnline=stat("Players online"); local sAliveN=stat("Players alive")
    function updateDash()
        local me=LocalPlayer
        teamLbl.Text="Team:  "..(me.Team and me.Team.Name or "—")
        sKills.Text=tostring(me:GetAttribute("InnocentKills") or 0)
        local allies,enemies,aliveN=0,0,0
        for _,p in ipairs(Players:GetPlayers()) do
            local ok=alive(p); if ok then aliveN+=1 end
            if p~=me and ok then if isEnemy(p) then enemies+=1 elseif p.Team==me.Team then allies+=1 end end
        end
        sAllies.Text=tostring(allies); sEnemies.Text=tostring(enemies)
        sOnline.Text=tostring(#Players:GetPlayers()); sAliveN.Text=tostring(aliveN)
        local h=hum()
        if h then local r=math.clamp(h.Health/math.max(h.MaxHealth,1),0,1)
            hpFill.Size=UDim2.new(r,0,1,0)
            hpFill.BackgroundColor3=Color3.fromRGB(math.floor(230*(1-r))+40,math.floor(200*r)+40,90)
            hpTxt.Text="HP  "..math.floor(h.Health).." / "..math.floor(h.MaxHealth)
            eHp.Size=UDim2.new(1,0,r,0); eHp.Position=UDim2.new(0,0,1-r,0); eHp.BackgroundColor3=hpFill.BackgroundColor3
        else hpFill.Size=UDim2.new(0,0,1,0); hpTxt.Text="HP  —" end
    end
    Hub._dashPage=pg.frame
end

--== AIMBOT ==--
do
    local pg=addTab("Aimbot")
    local sA=section(pg.left,"Aimbot")
    toggle(sA,"Enabled (auto-latch)",function() return F.Aim.On end,function(v) F.Aim.On=v end)
    dropdown(sA,"Enemies",function() return ENEMY_MODES end,function() return ENEMY_MODES[enemyMode] end,function(i) enemyMode=i end)
    dropdown(sA,"Target part",function() return {"Head","Torso"} end,function() return F.Aim.Part end,function(_,opt) F.Aim.Part=opt end)
    toggle(sA,"Wall check (visible only)",function() return F.Aim.WallCheck end,function(v) F.Aim.WallCheck=v end)
    toggle(sA,"Wallbang (lock thru walls)",function() return wallbang end,function(v) wallbang=v end)
    toggle(sA,"Silent aim (retargets your shots)",function() return F.Aim.Silent end,function(v) F.Aim.Silent=v end)
    toggle(sA,"Triggerbot (auto-fire)",function() return F.Aim.Trigger end,function(v) F.Aim.Trigger=v end)
    toggle(sA,"Show FOV circle",function() return F.Aim.ShowFOV end,function(v) F.Aim.ShowFOV=v end)
    local sT=section(pg.right,"Tuning")
    slider(sT,"FOV (px)",30,400,function() return F.Aim.FOV end,function(v) F.Aim.FOV=v end)
    slider(sT,"Smoothness",0.05,1,function() return F.Aim.Smooth end,function(v) F.Aim.Smooth=v end)
    slider(sT,"Prediction",0,1,function() return F.Aim.Predict end,function(v) F.Aim.Predict=v end)
    slider(sT,"Trigger delay (ms)",0,300,function() return F.Aim.TrigDelay end,function(v) F.Aim.TrigDelay=v end)
end

--== ESP ==--
do
    local pg=addTab("ESP")
    local sE=section(pg.left,"ESP")
    toggle(sE,"Enabled",function() return F.ESP.On end,function(v) F.ESP.On=v end)
    dropdown(sE,"Enemies are",function() return ENEMY_MODES end,function() return ENEMY_MODES[enemyMode] end,function(i) enemyMode=i end)
    toggle(sE,"Enemies only",function() return F.ESP.EnemiesOnly end,function(v) F.ESP.EnemiesOnly=v end)
    toggle(sE,"Boxes",function() return F.ESP.Box end,function(v) F.ESP.Box=v end)
    toggle(sE,"Filled boxes",function() return F.ESP.Filled end,function(v) F.ESP.Filled=v end)
    toggle(sE,"Names",function() return F.ESP.Name end,function(v) F.ESP.Name=v end)
    local sV=section(pg.right,"Details")
    toggle(sV,"Distance",function() return F.ESP.Dist end,function(v) F.ESP.Dist=v end)
    toggle(sV,"Health bars",function() return F.ESP.Health end,function(v) F.ESP.Health=v end)
    toggle(sV,"Tracers (red=enemy)",function() return F.ESP.Tracer end,function(v) F.ESP.Tracer=v end)
    toggle(sV,"Skeleton",function() return F.ESP.Skeleton end,function(v) F.ESP.Skeleton=v end)
end

--== PLAYERS ==--
do
    local pg=addTab("Players")
    local sT=section(pg.left,"Target")
    local plInfo=label(sT,"TARGET:  none")
    local function tgtRoot() local tc=plTarget and plTarget.Character; return tc and (tc:FindFirstChild("HumanoidRootPart") or tc:FindFirstChild("Torso")) end
    local dref
    local function refreshInfo()
        if plTarget and plTarget.Parent then local _,_,h=alive(plTarget)
            plInfo.Text="TARGET:  "..plTarget.Name.."\n"..(plTarget.Team and plTarget.Team.Name or "no team").."  ·  HP "..(h and math.floor(h.Health) or "?")
        else plInfo.Text="TARGET:  none" end
        if dref then dref.refresh() end
    end
    local function playerNames() local l={}; for _,p in ipairs(Players:GetPlayers()) do if p~=LocalPlayer then l[#l+1]=p.Name end end; return l end
    dref=dropdown(sT,"Select",playerNames,function() return plTarget and plTarget.Name or "none" end,function(_,name)
        plTarget=Players:FindFirstChild(name); refreshInfo() end)
    button(sT,"Refresh info",refreshInfo)
    local sAc=section(pg.right,"Actions")
    button(sAc,"RAGE  —  arm + TP + kill target",function()
        if not plTarget then return end
        if Hub._raging and Hub._raging() then return end
        doRage(plTarget)
    end)
    label(sAc,"grabs a gun if unarmed, blinks onto them, empties into their head")
    button(sAc,"Spectate (toggle)",function()
        if spectating then stopSpectate(); return end
        if not plTarget then return end
        spectateTarget=plTarget; spectating=true
    end)
    button(sAc,"Stop spectating",stopSpectate)
    button(sAc,"TP in front",function() local tr=tgtRoot(); if tr then tpMove(tr.CFrame*CFrame.new(0,0,-3)) end end)
    button(sAc,"TP behind",function() local tr=tgtRoot(); if tr then tpMove(tr.CFrame*CFrame.new(0,0,3)) end end)
    button(sAc,"TP on top",function() local tr=tgtRoot(); if tr then tpMove(tr.CFrame*CFrame.new(0,4,0)) end end)
    toggle(sAc,"Follow target",function() return plFollow end,function(v) plFollow=v end)
    Hub._tgtRoot=tgtRoot
end

--== CHARACTER ==--
do
    local pg=addTab("Character")
    local sS=section(pg.left,"Speed / Jump")
    toggle(sS,"Speed",function() return F.Mov.Speed end,function(v) F.Mov.Speed=v; local h=hum(); if h and not v then h.WalkSpeed=16 end end)
    slider(sS,"Walk speed",16,250,function() return F.Mov.SpeedV end,function(v) F.Mov.SpeedV=v end)
    toggle(sS,"Jump power",function() return F.Mov.JumpOn end,function(v) F.Mov.JumpOn=v; local h=hum(); if h and not v then h.UseJumpPower=true; h.JumpPower=50 end end)
    slider(sS,"Jump power value",50,400,function() return F.Mov.JumpV end,function(v) F.Mov.JumpV=v end)
    local sF=section(pg.right,"Fly / Misc")
    toggle(sF,"Fly (WASD Space/Ctrl)",function() return F.Mov.Fly end,function(v) F.Mov.Fly=v end)
    slider(sF,"Fly speed",0.5,10,function() return F.Mov.FlyV end,function(v) F.Mov.FlyV=v end)
    toggle(sF,"Noclip (pair with Fly)",function() return F.Mov.Noclip end,function(v) F.Mov.Noclip=v; if v then applyNoclip() else stopNoclip() end end)
    toggle(sF,"Infinite jump",function() return F.Mov.InfJump end,function(v) F.Mov.InfJump=v end)
    -- INVISIBLE — REMOVED. It does not work in Prison Life. Every method was tried live:
    --   • local transparency only hides your OWN screen — other players still see you.
    --   • making others lose sight of you is impossible here without breaking you:
    --       detaching your body KILLS the Humanoid; keeping it alive DRAGS you out of the map;
    --       the invisible-clone swap FREEZES your controls (needs a full rejoin to recover).
    -- There is no working server-side invis for this FE game, so the toggle is gone on purpose.
    label(sF,"Invisible:  not possible in this game — removed (see note in code)")
end

--== WORLD ==--
do
    local pg=addTab("World")
    local sL=section(pg.left,"Lighting")
    toggle(sL,"Fullbright",function() return F.Wld.Fullbright end,function(v) F.Wld.Fullbright=v; fullbright(v) end)
    toggle(sL,"No fog",function() return F.Wld.NoFog end,function(v) F.Wld.NoFog=v; if v then Lighting.FogEnd=1e9 end end)
    slider(sL,"Camera FOV",40,120,function() return F.Wld.FOV end,function(v) F.Wld.FOV=v; pcall(function() cam().FieldOfView=v end) end)

    -- item grabber: TP to a giver, grab it, TP back
    local sIt=section(pg.left,"Item grabber")
    local Remotes=game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    local GiverPressed=Remotes and Remotes:FindFirstChild("GiverPressed")
    local InteractItem=Remotes and Remotes:FindFirstChild("InteractWithItem")
    local itemMap={}
    local function scanNames()
        itemMap={}
        for _,d in ipairs(Workspace:GetDescendants()) do
            local tn=d:GetAttribute("ToolName")
            if tn and not itemMap[tn] then
                local part=d:IsA("BasePart") and d or d:FindFirstChildWhichIsA("BasePart",true)
                if part then itemMap[tn]=part end
            end
        end
        local ns={}; for n in pairs(itemMap) do ns[#ns+1]=n end; table.sort(ns); return ns
    end
    local selItem
    local function grab(part)
        local r=root(); if not (r and part and part.Parent) then return end
        local save=r.CFrame
        pcall(function() r.CFrame=CFrame.new(part.Position+Vector3.new(0,2.5,0)) end)
        task.wait(0.18)
        pcall(function() if GiverPressed then GiverPressed:FireServer(part) end end)
        pcall(function() if GiverPressed and part.Parent then GiverPressed:FireServer(part.Parent) end end)
        pcall(function() if InteractItem then InteractItem:InvokeServer(part) end end)
        task.wait(0.12)
        pcall(function() r.CFrame=save end)
    end
    dropdown(sIt,"Item",scanNames,function() return selItem or "select" end,function(_,n) selItem=n end)
    button(sIt,"Grab selected item",function()
        if not selItem then return end
        local part=itemMap[selItem]; if not part or not part.Parent then scanNames(); part=itemMap[selItem] end
        if part then task.spawn(function() grab(part) end) end
    end)
    label(sIt,"TPs to the item and back")

    local sSv=section(pg.right,"Server")
    toggle(sSv,"Anti-AFK",function() return F.Wld.AntiAFK end,function(v) F.Wld.AntiAFK=v end)
    button(sSv,"Rejoin server",function() pcall(function() game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId,game.JobId,LocalPlayer) end) end)
    button(sSv,"Server hop",function()
        local ok=pcall(function()
            local TS=game:GetService("TeleportService"); local HS=game:GetService("HttpService")
            local data=HS:JSONDecode(game:HttpGetAsync("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100"))
            for _,s in ipairs(data.data) do if s.playing<s.maxPlayers and s.id~=game.JobId then TS:TeleportToPlaceInstance(game.PlaceId,s.id,LocalPlayer); return end end
        end)
        if not ok then warn("[syntax] server hop failed (HTTP may be blocked)") end
    end)
end

--== TELEPORT ==--
do
    local pg=addTab("Teleport")
    local function tp(pos) tpMove(CFrame.new(pos)) end
    local sLoc=section(pg.left,"Locations")
    button(sLoc,"Criminal Base",function() tp(Vector3.new(-975,106,2058)) end)
    button(sLoc,"Criminal Armory",function() tp(Vector3.new(-928,93,2038)) end)
    button(sLoc,"Prison cells",function() tp(Vector3.new(917,98,2435)) end)
    button(sLoc,"Guard Armory",function() tp(Vector3.new(836,99,2229)) end)
    button(sLoc,"Cafeteria",function() tp(Vector3.new(949,98,2325)) end)
    button(sLoc,"Yard",function() tp(Vector3.new(872,96,2352)) end)
    button(sLoc,"Guard Booth",function() tp(Vector3.new(502,105,2230)) end)
    button(sLoc,"Void baseplate",function() tp(Vector3.new(872,38,2344)) end)
    local sWp=section(pg.right,"Waypoints")
    label(sWp,"Press  T  = click-TP to cursor")
    local wpCount=0
    button(sWp,"Save waypoint here",function()
        local r=root(); if not r then return end
        local wp=r.CFrame; wpCount=wpCount+1; local id=wpCount
        local row=make("Frame",{Size=UDim2.new(1,0,0,26),BackgroundColor3=T.item,BorderSizePixel=0},sWp); corner(row,4); stroke(row,T.line,1)
        local tpb=make("TextButton",{Size=UDim2.new(1,-32,1,0),Position=UDim2.fromOffset(10,0),BackgroundTransparency=1,Font=FONT,Text="› Waypoint "..id,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},row)
        tpb.MouseButton1Click:Connect(function() tpMove(wp) end)
        local del=make("TextButton",{Size=UDim2.fromOffset(22,18),Position=UDim2.new(1,-26,0.5,-9),BackgroundColor3=T.off,BorderSizePixel=0,AutoButtonColor=false,Font=FONT,Text="X",TextColor3=T.text,TextSize=11},row); corner(del,4)
        del.MouseEnter:Connect(function() tw(del,0.12,{BackgroundColor3=Color3.fromRGB(180,60,60)}) end)
        del.MouseLeave:Connect(function() tw(del,0.12,{BackgroundColor3=T.off}) end)
        del.MouseButton1Click:Connect(function() row:Destroy() end)
    end)
end

--== SETTINGS + CUSTOMIZATION ==--
do
    local pg=addTab("Settings")
    local sC=section(pg.left,"Customization")
    local presets={ {"Red",224,64,64},{"Pink",232,120,190},{"Blue",70,140,235},{"Green",90,200,130},{"Orange",235,145,60},{"Purple",165,110,235},{"Cyan",80,205,215},{"White",232,232,236} }
    local swatchRow=make("Frame",{Size=UDim2.new(1,0,0,26),BackgroundTransparency=1},sC)
    make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},swatchRow)
    local rV,gV,bV=224,64,64
    local rF,gF,bF
    for _,pr in ipairs(presets) do
        local col=Color3.fromRGB(pr[2],pr[3],pr[4])
        local sw=make("TextButton",{Size=UDim2.fromOffset(24,24),BackgroundColor3=col,BorderSizePixel=0,AutoButtonColor=false,Text=""},swatchRow); corner(sw,5); stroke(sw,T.line,1)
        sw.MouseButton1Click:Connect(function()
            rV,gV,bV=pr[2],pr[3],pr[4]; setAccent(col)
            if rF then rF(rV) end; if gF then gF(gV) end; if bF then bF(bV) end
        end)
        sw.MouseEnter:Connect(function() tw(sw,0.1,{Size=UDim2.fromOffset(27,27)}) end)
        sw.MouseLeave:Connect(function() tw(sw,0.1,{Size=UDim2.fromOffset(24,24)}) end)
    end
    local function cslider(text,init,setC)
        local r=make("Frame",{Size=UDim2.new(1,0,0,34),BackgroundTransparency=1},sC)
        make("TextLabel",{Size=UDim2.new(1,-44,0,15),BackgroundTransparency=1,Font=FONT,Text=text,TextColor3=T.text,TextXAlignment=Enum.TextXAlignment.Left,TextSize=12},r)
        local val=make("TextLabel",{Size=UDim2.new(0,42,0,15),Position=UDim2.new(1,-42,0,0),BackgroundTransparency=1,Font=FONT,Text=tostring(init),TextColor3=T.sub,TextXAlignment=Enum.TextXAlignment.Right,TextSize=12},r)
        local track=make("Frame",{Size=UDim2.new(1,0,0,6),Position=UDim2.fromOffset(0,22),BackgroundColor3=T.off,BorderSizePixel=0},r); corner(track,3)
        local fill=reg(make("Frame",{Size=UDim2.new(init/255,0,1,0),BackgroundColor3=T.accent,BorderSizePixel=0},track)); corner(fill,3)
        local drag=false
        local function setX(px) local a=math.clamp((px-track.AbsolutePosition.X)/track.AbsoluteSize.X,0,1)
            local v=math.floor(a*255); fill.Size=UDim2.new(a,0,1,0); val.Text=tostring(v); setC(v) end
        track.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true;setX(i.Position.X) end end)
        bind(UIS.InputChanged,function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then setX(i.Position.X) end end)
        bind(UIS.InputEnded,function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
        return function(v) fill.Size=UDim2.new(v/255,0,1,0); val.Text=tostring(v) end
    end
    rF=cslider("Accent R",rV,function(v) rV=v; setAccent(Color3.fromRGB(rV,gV,bV)) end)
    gF=cslider("Accent G",gV,function(v) gV=v; setAccent(Color3.fromRGB(rV,gV,bV)) end)
    bF=cslider("Accent B",bV,function(v) bV=v; setAccent(Color3.fromRGB(rV,gV,bV)) end)
    toggle(sC,"Falling boxes background",function() return F.UI.Boxes end,function(v) F.UI.Boxes=v; bgHost.Visible=v end)
    toggle(sC,"RGB accent (gamer mode)",function() return F.UI.RGB end,function(v) F.UI.RGB=v end)

    local sI=section(pg.right,"Info / Controls")
    label(sI,"syntax   ·   v5.8")
    label(sI,"Toggle UI:  Right Shift")
    label(sI,"Rage:  Players tab → select → RAGE (kick-safe)")
    label(sI,"Aimbot:  auto-latch (toggle on)")
    label(sI,"Click-TP:  T")
    label(sI,"Fly:  WASD + Space/Ctrl")
    button(sI,"Unload",function() Hub._unload() end)
end

selectTab("Dashboard")
task.defer(function() RunService.RenderStepped:Wait(); pcall(function() moveUnderline(tabBtns["Dashboard"].lbl,true) end) end)

local minimized=false
minB.MouseButton1Click:Connect(function()
    minimized=not minimized; tabBar.Visible=not minimized; body.Visible=not minimized; footer.Visible=not minimized
    bgHost.Visible=(not minimized) and F.UI.Boxes; underline.Visible=not minimized
    tw(win,0.2,{Size=minimized and UDim2.fromOffset(curW,34) or UDim2.fromOffset(curW,curH)},Enum.EasingStyle.Quart)
    minB.Text=minimized and "+" or "—" end)
closeB.MouseButton1Click:Connect(function() Hub._unload() end)

pcall(function()
    if not (Drawing and Drawing.new) then return end
    fovCircle=Drawing.new("Circle"); fovCircle.Thickness=1; fovCircle.NumSides=52; fovCircle.Color=T.accent; fovCircle.Filled=false; fovCircle.Visible=false
end)

bind(UIS.InputBegan,function(i,gpe)
    if i.UserInputType==Enum.UserInputType.MouseButton2 then F.Aim.Held=true end
    if gpe then return end
    if i.UserInputType==Enum.UserInputType.MouseButton1 then F.Aim.Fire=true end
    if i.KeyCode==Enum.KeyCode.RightShift then win.Visible=not win.Visible end
    if i.KeyCode==Enum.KeyCode.T then local m=LocalPlayer:GetMouse(); if m.Hit then tpMove(CFrame.new(m.Hit.Position+Vector3.new(0,3,0))) end end
    if F.Mov.InfJump and i.KeyCode==Enum.KeyCode.Space then local h=hum(); if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end end
end)
bind(UIS.InputEnded,function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton2 then F.Aim.Held=false end
    if i.UserInputType==Enum.UserInputType.MouseButton1 then F.Aim.Fire=false end
end)

pcall(function() local vu=game:GetService("VirtualUser")
    bind(LocalPlayer.Idled,function() if F.Wld.AntiAFK then vu:CaptureController(); vu:ClickButton2(Vector2.new()) end end) end)

bind(LocalPlayer.CharacterAdded,function()
    task.wait(0.4); invisSaved=nil
    if F.Mov.Noclip then applyNoclip() end
    if F.Mov.Invis then applyInvis(true) end
    if spectating then stopSpectate() end
end)

bind(RunService.Stepped,function()
    if attached and F.Mov.Noclip then local c=char()
        if c then for _,v in ipairs(c:GetDescendants()) do if v:IsA("BasePart") and v.CanCollide then v.CanCollide=false end end end end
end)

local lastFire=0
local lastDash=0
local lastSilent=0
local rgbHue=0
bind(RunService.RenderStepped,function(dt)
    if win.Visible and F.UI.Boxes and bgHost.Visible then
        for _,bx in ipairs(boxes) do
            bx.y=bx.y+bx.spd*dt
            if bx.y>WIN_H+24 then bx.y=-24-math.random(0,80); bx.x=math.random(0,WIN_W) end
            bx.f.Position=UDim2.fromOffset(bx.x,bx.y)
        end
    end
    if F.UI.RGB and win.Visible then rgbHue=(rgbHue+dt*0.14)%1; pcall(setAccent,Color3.fromHSV(rgbHue,0.72,1)) end
    pcall(ESP.render)
    if Hub._dashPage and Hub._dashPage.Visible and win.Visible then
        if dashRender then pcall(dashRender,dt) end
        if updateDash and os.clock()-lastDash>0.25 then lastDash=os.clock(); pcall(updateDash) end
    end
    if spectating then local st=spectateTarget; local tc=st and st.Character; local th=tc and tc:FindFirstChildOfClass("Humanoid")
        if th and th.Health>0 then pcall(function() cam().CameraSubject=th end) else stopSpectate() end end
    if not attached then if fovCircle then fovCircle.Visible=false end return end
    pcall(applyMovement,dt)
    if F.Wld.NoFog then Lighting.FogEnd=1e9 end
    if plFollow and Hub._tgtRoot then local r=root(); local tr=Hub._tgtRoot(); if r and tr then r.CFrame=tr.CFrame*CFrame.new(0,0,3.5) end end
    if fovCircle then fovCircle.Visible=F.Aim.On and F.Aim.ShowFOV; fovCircle.Radius=F.Aim.FOV; fovCircle.Position=aimOrigin() end
    if F.Aim.On then local t=wallbang and wallTarget() or Aim.getTarget()
        if t then local aimPos=t.Position+t.AssemblyLinearVelocity*F.Aim.Predict
            local cf=cam().CFrame; cam().CFrame=cf:Lerp(CFrame.new(cf.Position,aimPos),1-F.Aim.Smooth) end end
    if F.Aim.Trigger and (os.clock()-lastFire)*1000>=F.Aim.TrigDelay then
        local t=Aim.getTarget(10,true); if t then lastFire=os.clock(); fireClick() end end
    -- silent aim is handled by the ShootEvent hook (top of file): it rewrites your real shot in
    -- place, so there is nothing to do per-frame here and no extra shot is ever sent.
end)
bind(Players.PlayerRemoving,function(p) pcall(function() ESP.clear(p) end); if p==plTarget then plTarget=nil; plFollow=false end end)

function Hub._unload()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() applyServerInvis(false) end)
    pcall(clearNoclip); pcall(ESP.destroy); pcall(stopSpectate)
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    pcall(function() fullbright(false) end); pcall(function() cam().FieldOfView=70 end)
    pcall(function() gui:Destroy() end)
    local h=hum(); if h then h.WalkSpeed=16; h.JumpPower=50 end
    if getgenv then getgenv().syntax_wall=false; getgenv().syntax=nil end
end
Hub.Aim=Aim

warn("[syntax] v5.8 loaded — Right Shift toggles UI · Players→RAGE to kill a target · smooth TPs"..(Hub._silentHook and "" or "   [note: silent aim unavailable — executor lacks hookmetamethod]"))
