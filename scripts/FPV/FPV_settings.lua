local I     = require("openmw.interfaces")
local input = require('openmw.input')
local ui = require('openmw.ui')
local async = require('openmw.async')


I.Settings.registerRenderer("FPV_Body", function(v, set)
   local name = "none"
   if v then name = input.getKeyName(v) end
   return { template = I.MWUI.templates.box, content = ui.content {
   	{ template = I.MWUI.templates.padding, content = ui.content {
   		{ template = I.MWUI.templates.textEditLine,
   			props = { text = name, },
   			events = {
   				keyPress = async:callback(function(e)
   					if e.code == input.KEY.Escape then return end
   					set(e.code)
   				end),
   				},
   		},
   	}, },
   }, }
end)

I.Settings.registerRenderer("FPV_BodyKey", function() return {content = ui.content {}} end)


I.Settings.registerPage {
  key         = "tt_FPV_Body",
  l10n        = "FPVBody",
  name        = "FPVBody",
  description = "Settings to toggle FPVBody",
}

I.Settings.registerGroup({
  key              = "Settings_tt_FPVBody",
  page             = "tt_FPV_Body",
  l10n             = "FPVBody",
  name             = "FPVBody settings",
  permanentStorage = true,
  settings = {
     {
        key         = "FPVview",
   	 default     = input.KEY.Z,
        renderer    = 'FPV_Body',
        name        = "toggle view key",
        description = "key to toggle view",
     },
      {
         key = "ChooseRace",
         name = "Select your race",
         default = "Dark Elf",
         renderer = "select",
         argument = { disabled = false,
         l10n = "FPVBody", 
         items = { "Argonian", "Breton", "Dark Elf", "High Elf", "Imperial", "Khajiit", "Nord", "Orc", "Redguard", "Wood Elf" }
         },
      },	
	  {
         key = "ChooseSensitivity",
         name = "Select camera sensitivity",
         default = "Vanilla",
         renderer = "select",
         argument = { disabled = false,
         l10n = "FPVBody", 
         items = { "Vanilla", "Medium", "Sensitive" }
         },
      },	
	 
  },
})

return