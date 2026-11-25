-- Audio Abduction+: give the virtual sound card used for beaming a clear name.
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "matches", "alsa_output.platform-snd_aloop*" } } },
  apply_properties = {
    ["node.description"] = "Audio-Abduction+ (beam to Mac)",
    ["node.nick"] = "Audio-Abduction+",
  },
})
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "matches", "alsa_input.platform-snd_aloop*" } } },
  apply_properties = { ["node.disabled"] = true },
})
