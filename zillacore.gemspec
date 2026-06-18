require_relative "lib/zillacore/version"

Gem::Specification.new do |s|
  s.name        = "zillacore"
  s.version     = ZillaCore::VERSION
  s.summary     = "AI agent webhook receiver and dispatcher"
  s.description = "Webhook receiver that listens for Fizzy, GitHub, Discord, and Zoho Mail events, then dispatches work to AI agent CLIs."
  s.authors     = ["Andy Davis"]
  s.homepage    = "https://github.com/stowzilla/zillacore"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.cert_chain  = ['certs/stowzilla.pem']
  signing_key_path = File.expand_path('~/.ssh/gem-private_key.pem')
  s.signing_key = signing_key_path if File.exist?(signing_key_path)

  s.files = Dir[
    "lib/**/*",
    "bin/*",
    "receiver.rb",
    "views/**/*",
    "monitor/**/*",
    "templates/**/*",
    "script/*",
    "certs/*",
    "README.md",
    "CHANGELOG.md"
  ]
  s.executables = ["zillacore"]

  s.add_dependency "puma", "~> 7.2"
  s.add_dependency "rackup", "~> 2.3"
  s.add_dependency "sinatra", "~> 4.1"
  s.add_dependency "websocket-client-simple", "~> 0.8.0"

  s.add_development_dependency "rubocop", "~> 1.75"
  s.add_development_dependency "rubocop-performance", "~> 1.25"
  s.metadata["rubygems_mfa_required"] = "true"
end
