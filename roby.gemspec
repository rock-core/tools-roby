# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'roby/version'

Gem::Specification.new do |s|
  s.name = "roby"
  s.version = Roby::VERSION
  s.authors = ["Sylvain Joyeux"]
  s.email = "sylvain.joyeux@m4x.org"
  s.summary = "A plan-based control framework for autonomous systems"
  s.description = <<-EOD
The Roby plan manager is currently developped from within the Robot Construction
Kit (http://rock-robotics.org). Have a look there. Additionally, the [Roby User
Guide](http://rock-robotics.org/api/tools/roby) is a good place to start with
Roby.
  EOD
  s.homepage = "http://rock-robotics.org"
  s.licenses = ["BSD"]

  s.require_paths = ["lib"]
  s.extensions = ['ext/roby_bgl/extconf.rb', 'ext/roby_marshalling/extconf.rb', 'ext/value_set/extconf.rb']
  s.extra_rdoc_files = ["README.md"]
  s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }

  s.add_runtime_dependency "facets", ">= 2.4.0"
  s.add_runtime_dependency "utilrb", ">= 3.0.0"
  s.add_runtime_dependency "state_machine", "= 1.0.3"
  s.add_runtime_dependency "metaruby", '>= 1.0.0.a'
  s.add_runtime_dependency "rgl", '~> 0.5.1'
  s.add_runtime_dependency "websocket", '~> 1.2'
  s.add_runtime_dependency "binding_of_caller", '~> 0.7.0'
  s.add_runtime_dependency "rb-readline", '~> 0.5.3'
  s.add_runtime_dependency "concurrent-ruby", '~> 1.0'
  s.add_runtime_dependency "pastel", '~> 0.5.2', '>= 0.5.2'
  s.add_runtime_dependency "hooks", '~> 0.4.0', '>= 0.4.1'
  s.add_runtime_dependency "rubigen"
  s.add_runtime_dependency "rake-compiler", '~> 0.9.5'
  s.add_development_dependency "webgen", "< 1.0"
  s.add_development_dependency "minitest", ">= 5.0", "~> 5.0"
  s.add_development_dependency "flexmock", "~> 2.0", ">= 2.0.3"
  s.add_development_dependency "fakefs", '~> 0.6.0', ">= 0.6.7"
  s.add_development_dependency "simplecov", '~> 0.11.0', '>= 0.11.1'
end
