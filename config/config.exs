import Config

config :logger, :default_formatter,
  format: "[$level] $message\n",
  colors: [enabled: false]
