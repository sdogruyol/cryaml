# Compile-cost program: a typical small user of YAML (`YAML::Serializable`,
# `YAML.parse`, `to_yaml`). Built by `scripts/compile_cost.sh`.
{% if flag?(:stdlib_yaml) %}
  require "yaml"
{% else %}
  require "../../src/cryaml"
{% end %}

class Server
  include YAML::Serializable

  property host : String
  property port : Int32
  property tls : Bool = false
end

class Config
  include YAML::Serializable

  property name : String
  property version : String?
  property servers : Array(Server)
  property limits : Hash(String, Float64)
  property tags : Set(String) = Set(String).new
end

input = ARGV[0]? ? File.read(ARGV[0]) : <<-YAML
  name: app
  servers:
    - host: example.com
      port: 443
      tls: true
  limits: {cpu: 0.5, memory: 512.0}
  YAML

config = Config.from_yaml(input)
config.servers << Server.from_yaml("host: localhost\nport: 8080")
puts config.to_yaml
puts YAML.parse(input)["servers"][0]["host"].as_s
