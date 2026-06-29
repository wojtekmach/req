import Config

if config_env() == :test do
  config :logger, :default_formatter,
    format: "[$level] $message\n",
    colors: [enabled: false]
end
