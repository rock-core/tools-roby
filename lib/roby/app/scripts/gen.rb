require 'rubigen'
require 'rubigen/scripts/generate'
RubiGen::Base.__sources = [RubiGen::PathSource.new(:roby, File.join(Roby::ROBY_ROOT_DIR, "generators"))]

gen_name = ARGV.shift
RubiGen::Scripts::Generate.new.run(ARGV, :generator => gen_name)
