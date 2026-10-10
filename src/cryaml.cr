# cryaml: the stdlib `YAML` module on a pure Crystal YAML engine.
#
# `require "cryaml"` loads `src/yaml.cr`, the drop-in replacement for the
# stdlib's `yaml.cr`. Only the check below is specific to the shard.

require "./yaml"

# The stdlib's `require "yaml"` (also pulled in by `big/yaml`, `uri/yaml` and
# `uuid/yaml`) defines the same YAML module. Loaded after cryaml it would
# compile, because both load the same Any/Nodes/schema files, and its
# `PullParser` and `Builder` methods would silently replace cryaml's and link
# libyaml. A `finished` hook runs after every file is loaded, so this check
# catches either order.
module YAML
  macro finished
    {% if @top_level.has_constant?("LibYAML") %}
      {% raise <<-MSG
        cryaml: the stdlib's `yaml` is loaded together with `require "cryaml"`.

        Both define the YAML module and can't be used together. Replace
        `require "yaml"` with `require "cryaml"`, and `big/yaml`, `uri/yaml`,
        `uuid/yaml` with `cryaml/big`, `cryaml/uri`, `cryaml/uuid`. For
        dependencies you can't edit, see "Dependencies that require yaml" in
        cryaml's README.
        MSG
      %}
    {% end %}
  end
end
