# cryaml: the stdlib `YAML` module on a pure Crystal YAML engine.
#
# `require "cryaml"` loads `src/yaml.cr`, the drop-in replacement for the
# stdlib's `yaml.cr`. Only the check below is specific to the shard.

# The stdlib's `require "yaml"` defines the same YAML module, so loading both
# never compiles. When the stdlib came first, say why instead of failing on a
# duplicate definition. (When cryaml comes first, the stdlib fails with
# "alias Type is already defined" in `yaml/any.cr`.)
{% if @top_level.has_constant?("LibYAML") %}
  {% raise <<-MSG
    cryaml: the stdlib's `require "yaml"` was loaded before `require "cryaml"`.

    Both define the YAML module and can't be used together. Replace
    `require "yaml"` with `require "cryaml"`, and `big/yaml`, `uri/yaml`,
    `uuid/yaml` with `cryaml/big`, `cryaml/uri`, `cryaml/uuid`. For
    dependencies you can't edit, see "Dependencies that require yaml" in
    cryaml's README.
    MSG
  %}
{% end %}

require "./yaml"
