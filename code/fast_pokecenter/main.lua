-- Fast Pokecenter -- Nurse Joy greets you, heals your team, and lets you go.
--
-- Vanilla runs six beats for a heal you always accept:
--
--   "Good morning! Welcome to our POKéMON CENTER."      <- greeting
--   "We can heal your POKéMON to perfect health.
--    Shall we heal your POKéMON?"          [YES/NO]     <- prompt
--   "OK, may I see your POKéMON?"
--      ... healing animation ...
--   "Thank you for waiting. Your POKéMON are fully healed."
--   "We hope to see you again."                          <- + a button press
--
-- This keeps the greeting and the animation, answers the prompt for you, and
-- drops the routine lines and the button waits left behind with nothing to
-- read.
--
-- The seam is the engine's `script.command` hook (src/script/gen2/Vm.lua),
-- which hands a mod every opcode of a running script and keeps what it
-- returns. Returning without calling next() skips that opcode.
--
-- Nothing here hardcodes a ROM address. The nurse's entry point comes from the
-- std-script table BY NAME, and the rows to skip are derived by walking the
-- script graph: of every list the nurse can reach, exactly one holds the
-- `yesorno`, and that list is the routine body. Its lines are the routine
-- lines. The greeting lives in the time-of-day branches and the one-off
-- notices -- Pokerus, the phone-call registration -- live in their own, so
-- both survive. That reasoning holds for Gold and Silver at their own
-- addresses, not just Crystal's.

return function(mod)
  mod.options:define {
    { key = "enabled", type = "toggle", label = "FAST POKECENTER", default = true },
    -- Off: you still answer the prompt yourself, but the chatter around it
    -- is still cut.
    { key = "auto_accept", type = "toggle", label = "AUTO-ACCEPT HEAL",
      default = true },
    -- Default off: one press on the nurse takes you straight to the heal.
    -- On restores the time-of-day welcome. Either way the notices past the
    -- heal (Pokerus, phone registration) are untouched.
    { key = "keep_greeting", type = "toggle", label = "KEEP GREETING",
      default = false },
  }

  -- Resolved once, on the first script command of the session. Rows are keyed
  -- by IDENTITY -- the hook is handed the very table the dataset holds -- so
  -- nothing is matched by guessing at opcode order or text ids at runtime.
  local analysed, nurseKey = false, nil
  local skipRow, autoYesRow, greetingRow, greetingButton = {}, {}, {}, {}

  -- Returns true only when it actually found the nurse. The caller latches on
  -- that, NOT on having tried: the first script command of a session can
  -- easily arrive before the game or its dataset is resolvable -- more easily
  -- with other mods loaded, since they run scripts of their own during boot --
  -- and latching on the attempt left the mod permanently inert for the rest of
  -- the session with no sign that anything was wrong.
  local function analyse(data)
    if type(data) ~= "table" then return false end
    local std = data.gen2StdScripts and data.gen2StdScripts.scripts
    local entry = std and std.PokecenterNurseScript
    local scripts = data.gen2Scripts
    if not (entry and entry.key and scripts) then return false end
    nurseKey = entry.key

    local seen, lists, body, bodyKey = {}, {}, nil, nil
    local function walk(key)
      if type(key) ~= "string" or seen[key] then return end
      seen[key] = true
      local list = scripts[key]
      if type(list) ~= "table" then return end
      lists[#lists + 1] = list
      for _, row in ipairs(list) do
        if row.op == "yesorno" then body, bodyKey = list, key end
        if row.script then walk(row.script) end
      end
    end
    walk(entry.key)
    if not body then return false end

    -- Which lists are the GREETING side: those the entry reaches without
    -- going through the body. The Pokerus notice and the phone-call
    -- registration sit past the heal, so they are only reachable through it
    -- and are never treated as greeting -- otherwise turning the greeting off
    -- would silently swallow them too.
    local greetingList, gseen = {}, {}
    local function walkGreeting(key)
      if type(key) ~= "string" or gseen[key] or key == bodyKey then return end
      gseen[key] = true
      local list = scripts[key]
      if type(list) ~= "table" then return end
      greetingList[list] = true
      for _, row in ipairs(list) do
        if row.script then walkGreeting(row.script) end
      end
    end
    walkGreeting(entry.key)

    -- The routine lines, named by the text they write. Matching on the text id
    -- rather than the row catches the copies: the phone-call branch ends with
    -- its own "Thank you for waiting" / "We hope to see you again" rows, which
    -- are different tables saying the same thing.
    local routine = {}
    for _, row in ipairs(body) do
      if row.text and (row.op == "writetext" or row.op == "farwritetext") then
        routine[row.text] = true
      end
      if row.op == "yesorno" then autoYesRow[row] = true end
    end

    for _, list in ipairs(lists) do
      local texts, cut = 0, 0
      for _, row in ipairs(list) do
        if row.text and (row.op == "writetext" or row.op == "farwritetext") then
          texts = texts + 1
          if routine[row.text] then
            cut = cut + 1
            skipRow[row] = true
          elseif greetingList[list] then
            greetingRow[row] = true
          end
        end
      end
      -- A button wait only earns its keep while there is something on screen
      -- to read. Once every line in a list is cut, its waits are pressing A at
      -- an empty box -- which is most of what made the counter slow.
      if texts > 0 and cut == texts then
        for _, row in ipairs(list) do
          if row.op == "waitbutton" or row.op == "promptbutton" then
            skipRow[row] = true
          end
        end
      elseif texts > 0 and greetingList[list] then
        -- A greeting list's waits go only when its greeting does. A notice
        -- past the heal keeps both its line and its wait either way.
        for _, row in ipairs(list) do
          if row.op == "waitbutton" or row.op == "promptbutton" then
            greetingButton[row] = true
          end
        end
      end
    end
    return true
  end

  mod.hooks:wrap("script.command", function(nextFn, ctx, op, args, cmd)
    if not mod.options:get("enabled") then return nextFn() end
    -- Gen 1 runs its Pokemon Center in engine code rather than as a script,
    -- so it never reaches this hook.
    if not (ctx and ctx.generation == 2) then return nextFn() end

    if not analysed then
      local ok, result = pcall(analyse, mod.game and mod.game.data)
      if not ok then
        analysed = true
        mod.log:error("could not read the nurse script, standing down: %s",
          tostring(result))
      elseif result then
        analysed = true
        local n = 0
        for _ in pairs(skipRow) do n = n + 1 end
        mod.log:info("nurse script found at %s; %d rows to skip",
          tostring(nurseKey), n)
      end
    end
    -- NOT gated on ctx.scriptKey. The nurse object's script is a map-local
    -- one-liner (`jumpstd`) and `jumpstd` does not change the run's key, so
    -- ctx.scriptKey is that map's key -- 63:5b28 in Azalea -- never the std
    -- script's. Gating on it made this mod silently do nothing.
    --
    -- Scope comes from the row sets instead: they are built only from lists
    -- the nurse entry can reach, and the VM is handed the very tables this
    -- analysis walked (World passes data.gen2Scripts to Vm.new by reference),
    -- so a row from any other script is simply not in them.
    if not cmd then return nextFn() end

    if autoYesRow[cmd] then
      if not mod.options:get("auto_accept") then return nextFn() end
      -- `yesorno` yields a UI request and stores the answer in scriptVar, which
      -- the `iffalse` on the next row reads. Setting it directly and skipping
      -- the prompt is the same as choosing YES.
      local vm = ctx.vm
      if not vm then return nextFn() end
      vm.scriptVar = 1
      return
    end

    -- Leaving the prompt in place means its own button wait is still needed.
    if skipRow[cmd] then
      if not mod.options:get("auto_accept")
          and (op == "waitbutton" or op == "promptbutton") then
        return nextFn()
      end
      return
    end

    if not mod.options:get("keep_greeting")
        and (greetingRow[cmd] or greetingButton[cmd]) then
      return
    end

    return nextFn()
  end)

  mod.log:info("fast_pokecenter ready")
end
