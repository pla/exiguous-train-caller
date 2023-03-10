
data:extend({

	{
		type = "string-setting",
		name = "etc-arrival-action",
		setting_type = "runtime-per-user",
		default_value = "Manual",
		allowed_values = { "Automatic", "Manual"}, 
		allow_blank = false,
    order = "za",
	},
  {
    type = "int-setting",
    name = "etc-wait-min",
    setting_type = "runtime-per-user",
    minimum_value = 1,
    maximum_value=1000,
    default_value = 2,
    order = "zb",
  },

})
